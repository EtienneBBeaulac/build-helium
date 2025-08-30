#!/usr/bin/env bats

setup() {
  export LC_ALL=C LANG=C
  load helpers.bash
}

@test "errors outside a Gradle root" {
  run bash -lc "$BATS_TEST_DIRNAME/../tuner/helium-tune.sh 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"./gradlew not found"* ]]
}

@test "produces JSON on help task" {
  tmp=$(mktemp -d); pushd "$tmp" >/dev/null
  cat > ./gradlew <<'GRADLEW'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == "--stop" ]]; then exit 0; fi
if [[ "${1-}" == "-v" ]]; then echo "Gradle 8.7"; exit 0; fi
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -I) shift 2 ;;
    -q) shift ;;
    --*) shift ;;
    *) break ;;
  esac
done
task="${1:-help}"
if [[ "$task" == "help" ]]; then exit 0; else exit 1; fi
GRADLEW
  chmod +x ./gradlew
  HELIUM_FAKE_MEASURE=1 HELIUM_AGGRESSIVE_DAEMON_CLEAN=0 WARMUP_RUNS=0 MEASURED_RUNS=1 with_timeout 30 "$BATS_TEST_DIRNAME/../tuner/helium-tune.sh" help --no-progress --json-only --report-dir "$tmp/reports"
  [ -f "$tmp/reports/latest.json" ]
  jq -e '.gradle.task=="help" and .winner' "$tmp/reports/latest.json" >/dev/null
  popd >/dev/null
}

@test "bogus task returns rc=3" {
  tmp=$(mktemp -d); pushd "$tmp" >/dev/null
  cat > ./gradlew <<'GRADLEW'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == "--stop" ]]; then exit 0; fi
if [[ "${1-}" == "-v" ]]; then echo "Gradle 8.7"; exit 0; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -I) shift 2 ;;
    -q) shift ;;
    --*) shift ;;
    *) break ;;
  esac
done
task="${1:-help}"
if [[ "$task" == ":noSuchTask" ]]; then exit 1; fi
exit 0
GRADLEW
  chmod +x ./gradlew
  HELIUM_FAKE_MEASURE=1 HELIUM_AGGRESSIVE_DAEMON_CLEAN=0 run bash -lc "WARMUP_RUNS=0 MEASURED_RUNS=1 $BATS_TEST_DIRNAME/../tuner/helium-tune.sh :noSuchTask --no-progress --json-only --report-dir $tmp/reports"
  [ "$status" -eq 3 ]
  popd >/dev/null
}


