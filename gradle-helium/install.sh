#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-https://raw.githubusercontent.com/YOUR_GH_USER/gradle-sweetspot/main}"

BIN_DIR="${HOME}/bin"
GRADLE_INIT_DIR="${HOME}/.gradle/init.d"
CFG_FILE="${HOME}/.gradle/gradle-tuner.json"

mkdir -p "${BIN_DIR}" "${GRADLE_INIT_DIR}"

fetch() { curl -fsSL "${REPO_ROOT}/$1" -o "$2"; }

echo "[gradle-sweetspot] Installing..."

# 1) CLI
fetch "tuner/gradle-tune.sh" "${BIN_DIR}/gradle-tune"
chmod +x "${BIN_DIR}/gradle-tune"

# 2) Init scripts (enforce config + add synthetic tasks)
fetch "init/gradle-tuner.init.gradle.kts"        "${GRADLE_INIT_DIR}/gradle-tuner.init.gradle.kts"
fetch "init/sweetspot-benchmark.init.gradle.kts" "${GRADLE_INIT_DIR}/sweetspot-benchmark.init.gradle.kts"

# 3) PATH
if ! command -v gradle-tune >/dev/null 2>&1; then
  PROFILE="${HOME}/.zshrc"
  [ -n "${BASH_VERSION:-}" ] && PROFILE="${HOME}/.bashrc"
  if ! grep -qs 'export PATH="$HOME/bin:$PATH"' "${PROFILE}"; then
    echo 'export PATH="$HOME/bin:$PATH"' >> "${PROFILE}"
    echo "[gradle-sweetspot] Added ${HOME}/bin to PATH in ${PROFILE}. Restart your shell."
  fi
fi

# 4) Default config
if [ ! -f "${CFG_FILE}" ]; then
  cat > "${CFG_FILE}" <<JSON
{
  "gradleVersionKey": "",
  "gradleJvmArgs": "-Xms512m -Xmx4g -XX:+UseG1GC -Dfile.encoding=UTF-8",
  "kotlinDaemonJvmArgs": "-Xms256m -Xmx2g -XX:+UseG1GC",
  "workersMax": 4
}
JSON
  echo "[gradle-sweetspot] Wrote default ${CFG_FILE}"
fi

echo "[gradle-sweetspot] Installed."
echo "Try: gradle-tune            # uses synthetic sweetspotBenchmark"
echo "   or gradle-tune ':app:assembleDebug'    # tune against a real task"