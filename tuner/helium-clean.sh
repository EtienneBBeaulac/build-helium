#!/usr/bin/env bash
set -euo pipefail

# build-helium — cleanup helper: deletes build/helium in the current Gradle project (all subprojects)

if [[ ! -x ./gradlew ]]; then
  echo "Error: ./gradlew not found. Run helium-clean from a Gradle project root." >&2
  exit 2
fi

./gradlew -q heliumClean || ./gradlew heliumClean
echo "build-helium: cleaned build/helium across all projects."


