#!/usr/bin/env zsh
# [git-worktrees] zsh helpers for managing git worktrees
# Version: 0.1.0
# Homepage: https://github.com/EtienneBBeaulac/build-helium

# Avoid setting options that might interfere with a user's shell; leave behavior minimal

__gw_prefix="[git-worktrees]"

# Colors are optional; respect NO_COLOR and non-TTY environments
__gw_use_color=true
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
  __gw_use_color=false
fi
if $__gw_use_color 2>/dev/null; then
  if command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    __gw_c_dim=$(tput dim)
    __gw_c_bold=$(tput bold)
    __gw_c_reset=$(tput sgr0)
    __gw_c_green=$(tput setaf 2)
    __gw_c_yellow=$(tput setaf 3)
    __gw_c_cyan=$(tput setaf 6)
    __gw_c_gray=$(tput setaf 8)
  else
    __gw_use_color=false
  fi
fi
if ! $__gw_use_color 2>/dev/null; then
  __gw_c_dim=""; __gw_c_bold=""; __gw_c_reset="";
  __gw_c_green=""; __gw_c_yellow=""; __gw_c_cyan=""; __gw_c_gray="";
fi

__gw_echo() {
  echo "${__gw_prefix} $*"
}

__gw_has() { command -v "$1" >/dev/null 2>&1; }

__gw_is_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

__gw_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

__gw_default_branch() {
  # Try origin/HEAD, fallback to main, then master
  local ref
  ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -n "$ref" ]]; then
    echo "${ref##origin/}"
    return 0
  fi
  if git show-ref --quiet refs/heads/main; then echo main; return 0; fi
  if git show-ref --quiet refs/heads/master; then echo master; return 0; fi
  echo main
}

__gw_worktrees_dir() {
  local root
  root="$(__gw_repo_root)"
  echo "$root/.worktrees"
}

__gw_select() {
  # Select one item from stdin; prefer fzf if available, else present a numbered menu
  if __gw_has fzf; then
    fzf --ansi --prompt="Select worktree: " --height=40% --reverse
    return
  fi
  # Fallback simple selector
  local items item i=0
  items=()
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    items+=("$item")
  done
  local n=${#items[@]}
  if (( n == 0 )); then return 1; fi
  local idx
  local -i j
  for (( j=1; j<=n; j++ )); do
    printf "%2d) %s\n" "$j" "$items[$j]"
  done
  printf "Enter choice [1-%d]: " "$n"
  read -r idx
  if [[ "$idx" =~ '^[0-9]+$' ]] && (( idx>=1 && idx<=n )); then
    echo "$items[$idx]"
    return 0
  fi
  return 1
}

wtls() {
  if ! __gw_is_git_repo; then
    __gw_echo "Not inside a git repository"
    return 1
  fi
  local line path branch sha status
  git worktree list --porcelain | while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ refs/heads/*) branch="${line#branch refs/heads/}" ;;
      bare) branch="(bare)" ;;
      detachd\ *) sha="${line#detached }" ;;
      lock\ *) status="(locked)" ;;
      *) ;;
    esac
    if [[ -n "$path" && ( -n "$branch" || -n "$sha" ) ]]; then
      printf "%s %s%s%s\n" "$path" "$__gw_c_cyan" "${branch:-$sha}" "$__gw_c_reset"
      path=""; branch=""; sha=""; status=""
    fi
  done
}

wtnew() {
  # Usage: wtnew <branch> [path] [--base <base>]
  if ! __gw_is_git_repo; then
    __gw_echo "Not inside a git repository"
    return 1
  fi
  local branch path base
  base=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      *) if [[ -z "${branch:-}" ]]; then branch="$1"; else path="$1"; fi; shift ;;
    esac
  done
  if [[ -z "${branch:-}" ]]; then
    __gw_echo "Usage: wtnew <branch> [path] [--base <base-branch>]"
    return 2
  fi
  if [[ -z "${path:-}" ]]; then
    path="$(__gw_worktrees_dir)/$branch"
  fi
  mkdir -p "$(__gw_worktrees_dir)"
  base=${base:-$(__gw_default_branch)}
  __gw_echo "Adding worktree for ${__gw_c_bold}$branch${__gw_c_reset} from ${base}"
  git fetch --all --prune --quiet || true
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git worktree add -B "$branch" "$path" "$branch"
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git worktree add -B "$branch" "$path" "origin/$branch"
  else
    git worktree add -B "$branch" "$path" "$base"
  fi
  __gw_echo "Created: $path"
}

wtopen() {
  # Usage: wtopen [path-or-branch]
  if ! __gw_is_git_repo; then
    __gw_echo "Not inside a git repository"
    return 1
  fi
  local arg dest
  arg="${1:-}"
  if [[ -n "$arg" ]]; then
    if [[ -d "$arg" ]]; then dest="$arg"; else dest="$(__gw_worktrees_dir)/$arg"; fi
  else
    dest=$(wtls | __gw_select | awk '{print $1}') || return 1
  fi
  if [[ ! -d "$dest" ]]; then
    __gw_echo "No such worktree directory: $dest"
    return 1
  fi
  cd "$dest"
}

wtrm() {
  # Usage: wtrm [path-or-branch]
  if ! __gw_is_git_repo; then
    __gw_echo "Not inside a git repository"
    return 1
  fi
  local arg target
  arg="${1:-}"
  if [[ -n "$arg" ]]; then
    if [[ -d "$arg" ]]; then target="$arg"; else target="$(__gw_worktrees_dir)/$arg"; fi
  else
    target=$(wtls | __gw_select | awk '{print $1}') || return 1
  fi
  if [[ ! -d "$target" ]]; then
    __gw_echo "No such worktree directory: $target"
    return 1
  fi
  __gw_echo "Removing: $target"
  git worktree remove "$target"
}

# Completion helpers (lightweight)
_wt_branches() {
  git for-each-ref --format='%(refname:short)' refs/heads
}
# Note: completions intentionally omitted to avoid sourcing-order conflicts


