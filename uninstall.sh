#!/usr/bin/env bash
set -euo pipefail

# build-helium uninstaller
# Removes installed CLI and init scripts; leaves user reports/configs intact.

BIN_DIR="${HOME}/bin"
GRADLE_INIT_DIR="${HOME}/.gradle/init.d"

remove_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    rm -f "$path" || true
    echo "Removed: $path"
  fi
}

remove_if_exists "${BIN_DIR}/helium-tune"
remove_if_exists "${BIN_DIR}/helium-clean"
remove_if_exists "${BIN_DIR}/build-helium-render-md"
remove_if_exists "${BIN_DIR}/build-helium-render-html"
remove_if_exists "${GRADLE_INIT_DIR}/gradle-tuner.init.gradle.kts"
remove_if_exists "${GRADLE_INIT_DIR}/helium-benchmark.init.gradle.kts"

echo "build-helium uninstall complete."

