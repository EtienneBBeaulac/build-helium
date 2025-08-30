#!/usr/bin/env bash
set -euo pipefail

# [git-worktrees] Installer — zsh helpers for git worktrees
# Installs: ~/.config/git-worktrees/git-worktrees.zsh and sources from ~/.zshrc

# ---------- Branding / Colors ----------
BRAND="[git-worktrees]"
EMOJI_OK=""
EMOJI_WARN=""
EMOJI_FAIL=""

USE_COLOR=true
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
  USE_COLOR=false
fi
if command -v tput >/dev/null 2>&1; then
  COLORS=$(tput colors 2>/dev/null || echo 0)
else
  COLORS=0
fi
if [[ "$COLORS" -lt 8 ]]; then USE_COLOR=false; fi

if $USE_COLOR; then
  C_RESET="$(tput sgr0)"
  C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"; C_RED="$(tput setaf 1)"; C_GRAY="$(tput setaf 8)"
  EMOJI_OK="✅ "; EMOJI_WARN="⚠️  "; EMOJI_FAIL="❌ "
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""
fi

# ---------- Defaults ----------
REPO_ROOT_DEFAULT="https://raw.githubusercontent.com/EtienneBBeaulac/build-helium/main"
REPO_ROOT="${REPO_ROOT:-$REPO_ROOT_DEFAULT}"

DEST_DIR="${HOME}/.config/git-worktrees"
DEST_FILE="${DEST_DIR}/git-worktrees.zsh"
ZSHRC="${HOME}/.zshrc"

DRY_RUN=false
QUIET=false
VERBOSE=false
NO_SOURCE=false
FORCE=false
REINSTALL=false

# ---------- Logging ----------
log() {
  if $QUIET; then return 0; fi
  printf "%s %s\n" "$BRAND" "$*"
}
logv() { if $VERBOSE; then log "$*"; fi }
warn() { printf "%s %s%s%s\n" "$BRAND" "$C_YELLOW$EMOJI_WARN" "$*" "$C_RESET"; }
err() { printf "%s %s%s%s\n" "$BRAND" "$C_RED$EMOJI_FAIL" "$*" "$C_RESET" 1>&2; }
ok()  { printf "%s %s%s%s\n" "$BRAND" "$C_GREEN$EMOJI_OK" "$*" "$C_RESET"; }

run() {
  if $DRY_RUN; then
    logv "DRY-RUN: $*"
  else
    eval "$*"
  fi
}

# Align a left string to a given width
pad_right() {
  local s="$1" w="$2"; local n=${#s}
  if (( n >= w )); then printf "%s" "$s"; else printf "%s%*s" "$s" $(( w - n )) ""; fi
}

# Cross-platform stat size
file_size_bytes() {
  local f="$1"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    stat -f%z "$f" 2>/dev/null || echo 0
  else
    stat -c%s "$f" 2>/dev/null || echo 0
  fi
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# ---------- Args ----------
usage() {
  cat <<EOF
$BRAND Installer

Usage: install.sh [--verbose] [--quiet] [--dry-run] [--no-source] [--force] [--reinstall]

Flags:
  --verbose     Increase logging
  --quiet       Minimal output
  --dry-run     Show actions without making changes
  --no-source   Do not modify ~/.zshrc (print next steps instead)
  --force       Overwrite changed files, back up existing with timestamp
  --reinstall   Overwrite even if unchanged (implies --force)

Quick commands after install:
  wtnew <branch> [path] [--base <base>]   # create worktree
  wtopen [branch|path]                     # cd into a worktree
  wtrm [branch|path]                       # remove a worktree
  wtls                                     # list worktrees

See README for details.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --verbose) VERBOSE=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-source) NO_SOURCE=true; shift ;;
    --force) FORCE=true; shift ;;
    --reinstall) REINSTALL=true; FORCE=true; shift ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    *) err "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

# ---------- Preflight ----------
OS="$(uname -s || true)"
pkg_hint() {
  case "$OS" in
    Darwin) echo "brew install $1" ;;
    Linux)  echo "apt install -y $1 (or your distro's package manager)" ;;
    *)      echo "install $1 via your OS package manager" ;;
  esac
}

preflight_pass=true

check_cmd() {
  local name="$1" optional="${2:-}"
  if command -v "$name" >/dev/null 2>&1; then
    ok "PASS ${name}"
  else
    if [[ "$optional" == "optional" ]]; then
      warn "MISS ${name} (optional) — $(pkg_hint "$name")"
    else
      err "FAIL ${name} — $(pkg_hint "$name")"
      preflight_pass=false
    fi
  fi
}

log "Preflight checks"
check_cmd git
check_cmd zsh
check_cmd curl
check_cmd fzf optional

if ! $preflight_pass; then
  err "Preflight failed — install missing dependencies and re-run."
  exit 1
fi

# ---------- Idempotent dirs ----------
log "Ensuring directories"
run "mkdir -p '$DEST_DIR'"

# ---------- Fetch file (with status) ----------
TMP_DIR="$(mktemp -d -t gw-install-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

REMOTE_FILE_URL="${REPO_ROOT}/worktrees/git-worktrees.zsh"
TMP_REMOTE_FILE="${TMP_DIR}/git-worktrees.zsh"

print_fetch_line() {
  local left right size
  left="$(pad_right "${REMOTE_FILE_URL} -> ${DEST_FILE}" 86)"
  right="$1"
  printf "%s %s%s%s %s\n" "$BRAND" "$C_GRAY" "$left" "$C_RESET" "$right"
}

log "Installing files"
print_fetch_line "fetching"
if $DRY_RUN; then
  : # skip network
else
  curl -fsSL "$REMOTE_FILE_URL" -o "$TMP_REMOTE_FILE"
fi

updated_status="new"
backup_path=""

if [[ -f "$DEST_FILE" ]]; then
  if $DRY_RUN; then
    updated_status="check"
  else
    if [[ -s "$TMP_REMOTE_FILE" ]]; then
      if [[ "$(sha256 "$DEST_FILE")" == "$(sha256 "$TMP_REMOTE_FILE")" ]]; then
        updated_status="unchanged"
      else
        updated_status="updated"
      fi
    fi
  fi
fi

if $DRY_RUN; then
  print_fetch_line "would install (${updated_status})"
else
  if [[ "$updated_status" == "unchanged" && $REINSTALL == false && $FORCE == false ]]; then
    size=$(file_size_bytes "$DEST_FILE")
    print_fetch_line "unchanged (${size} B)"
  else
    if [[ -f "$DEST_FILE" ]]; then
      ts="$(date +%Y%m%d%H%M%S)"
      backup_path="${DEST_FILE}.bak-${ts}"
      run "cp '$DEST_FILE' '$backup_path'"
    fi
    run "install -m 0644 '$TMP_REMOTE_FILE' '$DEST_FILE'"
    size=$(file_size_bytes "$DEST_FILE")
    if [[ "$updated_status" == "new" ]]; then
      print_fetch_line "installed (${size} B)"
    elif [[ "$updated_status" == "updated" || $REINSTALL == true || $FORCE == true ]]; then
      print_fetch_line "updated (${size} B)"
    else
      print_fetch_line "installed (${size} B)"
    fi
  fi
fi

# ---------- zshrc integration ----------
BLOCK_BEGIN="# >>> git-worktrees >>>"
BLOCK_END="# <<< git-worktrees <<<"
SOURCE_LINE="source \"${DEST_FILE}\""
BLOCK_CONTENT="${BLOCK_BEGIN}
# Add git worktrees helpers
${SOURCE_LINE}
${BLOCK_END}"

zshrc_changed=false
zshrc_blockers=()

if ! $NO_SOURCE; then
  if $DRY_RUN; then
    log "Would ensure sourcing block in ${ZSHRC}"
  else
    run "touch '$ZSHRC'"
    if grep -qs "${BLOCK_BEGIN}" "$ZSHRC"; then
      logv "Block already present in .zshrc"
    else
      ts="$(date +%Y%m%d%H%M%S)"
      run "printf '\n%s\n' '${BLOCK_CONTENT}' >> '$ZSHRC'"
      zshrc_changed=true
    fi
  fi
else
  warn "Skipping .zshrc changes (--no-source)."
fi

# Detect simple blockers in .zshrc
if [[ -f "$ZSHRC" ]]; then
  if grep -qE '^\s*return\b' "$ZSHRC"; then
    zshrc_blockers+=("top-level return present — may block sourcing in some contexts")
  fi
fi

# ---------- Self-test ----------
selftest_ok=true
selftest_msg=""
if $DRY_RUN; then
  log "Self-test skipped (dry-run)."
else
  if zsh -c "emulate -L zsh; source '${DEST_FILE}'; whence wtnew wtopen wtrm wtls >/dev/null"; then
    ok "Self-test: functions found (wtnew, wtopen, wtrm, wtls)"
  else
    selftest_ok=false
    selftest_msg="Could not load functions from ${DEST_FILE}"
    err "Self-test failed — ${selftest_msg}"
  fi
fi

# ---------- Summary ----------
echo
log "Summary"
installed_list="${DEST_FILE}"
if [[ -n "${backup_path}" ]]; then
  log "Backups: ${backup_path}"
fi
log "Installed: ${installed_list}"
if $NO_SOURCE; then
  log "Next steps: add to ~/.zshrc → ${SOURCE_LINE}"
else
  log "Next steps: restart your shell or run: source ~/.zshrc"
fi
if ((${#zshrc_blockers[@]} > 0)); then
  warn "$HOME/.zshrc blockers detected:"
  for b in "${zshrc_blockers[@]}"; do log "  - ${b}"; done
fi

echo
log "Available commands:"
echo "  wtnew <branch> [path] [--base <base>]   # create worktree"
echo "  wtopen [branch|path]                     # cd into a worktree"
echo "  wtrm [branch|path]                       # remove a worktree"
echo "  wtls                                     # list worktrees"

exit 0


