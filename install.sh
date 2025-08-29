#!/usr/bin/env bash
set -euo pipefail

# ---------- Config ----------
# Allow overrides via env (use your org/user if you fork)
REPO_ROOT="${REPO_ROOT:-https://raw.githubusercontent.com/EtienneBBeaulac/build-helium/main}"

BIN_DIR="${HOME}/bin"
GRADLE_INIT_DIR="${HOME}/.gradle/init.d"
REPORT_CFG="${HOME}/.gradle/gradle-tuner.json"   # kept for compatibility with init script

# ---------- Helpers ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
fetch() {
  local src="${REPO_ROOT}/$1" dst="$2"
  echo "[build-helium] Fetching $src -> $dst"
  curl -fsSL "$src" -o "$dst"
}

# ---------- Checks ----------
need curl

# ---------- Create dirs ----------
mkdir -p "$BIN_DIR" "$GRADLE_INIT_DIR"

echo "[build-helium] Installing…"

# ---------- 1) CLI (tuner) ----------
fetch "tuner/helium-tune.sh" "${BIN_DIR}/helium-tune"
chmod +x "${BIN_DIR}/helium-tune"

# Cleanup CLI
fetch "tuner/helium-clean.sh" "${BIN_DIR}/helium-clean"
chmod +x "${BIN_DIR}/helium-clean"

# ---------- 2) Renderers (JSON -> Markdown/HTML) ----------
fetch "tuner/render_md.sh"   "${BIN_DIR}/build-helium-render-md"
fetch "tuner/render_html.sh" "${BIN_DIR}/build-helium-render-html"
chmod +x "${BIN_DIR}/build-helium-render-md" "${BIN_DIR}/build-helium-render-html"

# ---------- 3) Init scripts ----------
# (a) Global enforcement init script — reads ~/.gradle/gradle-tuner.json
fetch "init/gradle-tuner.init.gradle.kts" "${GRADLE_INIT_DIR}/gradle-tuner.init.gradle.kts"

# (b) Synthetic benchmark tasks (heliumBenchmark / heliumBenchmarkBig)
fetch "init/helium-benchmark.init.gradle.kts" "${GRADLE_INIT_DIR}/helium-benchmark.init.gradle.kts"

# ---------- 4) PATH setup ----------
# Ensure ~/bin is on PATH for the user's login shell in future sessions
OS="$(uname -s || true)"
LOGIN_SHELL="${SHELL:-}"
if [[ -z "$LOGIN_SHELL" ]] && command -v dscl >/dev/null 2>&1; then
  LOGIN_SHELL="$(dscl . -read "/Users/${USER}" UserShell 2>/dev/null | awk '{print $2}' || true)"
fi

declare -a PROFILE_FILES=()
if [[ "$LOGIN_SHELL" == */zsh ]]; then
  # On macOS, zsh reads .zprofile for login shells and .zshrc for interactive shells
  PROFILE_FILES+=("${HOME}/.zshrc")
  [[ "$OS" == "Darwin" ]] && PROFILE_FILES+=("${HOME}/.zprofile")
elif [[ "$LOGIN_SHELL" == */bash ]]; then
  if [[ "$OS" == "Darwin" ]]; then
    PROFILE_FILES+=("${HOME}/.bash_profile")
  else
    PROFILE_FILES+=("${HOME}/.bashrc")
  fi
else
  PROFILE_FILES+=("${HOME}/.profile")
fi

if ! echo ":$PATH:" | grep -q ":${HOME}/bin:"; then
  for PROFILE in "${PROFILE_FILES[@]}"; do
    if ! grep -qs 'export PATH="$HOME/bin:$PATH"' "$PROFILE"; then
      echo 'export PATH="$HOME/bin:$PATH"' >> "$PROFILE"
      echo "[build-helium] Added \$HOME/bin to PATH in ${PROFILE}. Restart your shell or 'source' your profile."
    fi
  done
fi

# ---------- 5) Seed default config (only if missing) ----------
if [[ ! -f "$REPORT_CFG" ]]; then
  cat > "$REPORT_CFG" <<JSON
{
  "gradleVersionKey": "",
  "gradleJvmArgs": "-Xms512m -Xmx4g -XX:+UseG1GC -Dfile.encoding=UTF-8",
  "kotlinDaemonJvmArgs": "-Xms256m -Xmx2g -XX:+UseG1GC",
  "workersMax": 4
}
JSON
  echo "[build-helium] Wrote default ${REPORT_CFG}"
fi

# ---------- 6) Friendly summary ----------
echo "[build-helium] Installed."
echo "Commands:"
echo "  helium-tune                     # tune using synthetic heliumBenchmark"
echo "  helium-tune ':app:assembleDebug'  # tune against your real build"
echo "  helium-clean                   # delete build/helium across all projects"
echo
echo "Renderer helpers (optional to run manually):"
echo "  build-helium-render-md   <report.json> [out.md]"
echo "  build-helium-render-html <report.json> [out.html]"