#!/usr/bin/env bash
set -euo pipefail

# Default = synthetic benchmark task installed by our init script.
TASK="${1:-sweetspotBenchmark}"

# Allow a quick "--big" flag to use the heavier variant
if [[ "${TASK}" == "--big" ]]; then
  TASK="sweetspotBenchmarkBig"
elif [[ "${TASK}" == "--help" || "${TASK}" == "-h" ]]; then
  cat <<'HELP'
gradle-tune [TASK]

Without arguments, tunes using "sweetspotBenchmark" (synthetic heavy task).
You can pass any real Gradle task instead, e.g. ":app:assembleDebug".
Flags:
  --big          Use "sweetspotBenchmarkBig"
Env overrides:
  W_T W_R W_G    Score weights (time, RSS, GC)
  WARMUP_RUNS    Warmup iterations (default 1)
  MEASURED_RUNS  Measured iterations (default 2)
HELP
  exit 0
fi

WARMUP_RUNS=${WARMUP_RUNS:-1}
MEASURED_RUNS=${MEASURED_RUNS:-2}
GCLOG_DIR="/tmp/gradle-tuner-gc"
JSON_OUT="${HOME}/.gradle/gradle-tuner.json"
GRADLE_VERSION_KEY="$(./gradlew -v 2>/dev/null | awk '/Gradle /{print $2; exit}' || echo "")"

mkdir -p "${GCLOG_DIR}"

# Detect cores/RAM (macOS & Linux)
detect_cores(){ command -v sysctl >/dev/null && sysctl -n hw.ncpu || nproc; }
detect_ram_gb(){
  if command -v sysctl >/dev/null; then
    echo $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
  else
    echo $(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
  fi
}
CORES="$(detect_cores)"
RAM_GB="$(detect_ram_gb)"

# Candidate matrix — keeps heap < 32g (compressed oops ON)
declare -a CANDIDATES
if [ "${RAM_GB}" -ge 64 ]; then
  CANDIDATES+=("4g 2g $(( CORES>6?6:CORES ))")
  CANDIDATES+=("6g 3g $(( CORES>6?6:CORES ))")
  CANDIDATES+=("8g 4g $(( CORES>6?6:CORES ))")
elif [ "${RAM_GB}" -ge 32 ]; then
  CANDIDATES+=("4g 2g $(( CORES>6?6:CORES ))")
  CANDIDATES+=("6g 3g $(( CORES>6?6:CORES ))")
else
  CANDIDATES+=("3g 2g $(( CORES>4?4:CORES ))")
  CANDIDATES+=("4g 2g $(( CORES>4?4:CORES ))")
fi

W_T=${W_T:-1.0}
W_R=${W_R:-0.00001}
W_G=${W_G:-5.0}

echo "gradle-sweetspot: ${CORES} cores, ${RAM_GB} GB RAM"
echo "Task: ${TASK}"
echo "Candidates:"; for c in "${CANDIDATES[@]}"; do echo "  $c"; done

measure_case() {
  local name="$1" gr_xmx="$2" kt_xmx="$3" workers="$4"
  local GR_JVMARGS="-Xms512m -Xmx${gr_xmx} -XX:+UseG1GC -Dfile.encoding=UTF-8 -Xlog:gc*:file=${GCLOG_DIR}/gradle-gc-${name}.log:tags,uptime,level"
  local KT_JVMARGS="-Xms256m -Xmx${kt_xmx} -XX:+UseG1GC -Xlog:gc*:file=${GCLOG_DIR}/kotlin-gc-${name}.log:tags,uptime,level"

  # Override project gradle.properties via env (ORG_GRADLE_PROJECT_*)
  export ORG_GRADLE_PROJECT_org__gradle__jvmargs="${GR_JVMARGS}"
  export ORG_GRADLE_PROJECT_kotlin__daemon__jvmargs="${KT_JVMARGS}"
  export ORG_GRADLE_PROJECT_org__gradle__workers__max="${workers}"

  ./gradlew --stop >/dev/null 2>&1 || true
  [ -n "${GRADLE_VERSION_KEY}" ] && rm -rf "${HOME}/.gradle/daemon/${GRADLE_VERSION_KEY}" >/dev/null 2>&1 || true

  for _ in $(seq 1 "${WARMUP_RUNS}"); do ./gradlew -q "${TASK}" >/dev/null || true; done

  local total=0 rss_peak=0
  for i in $(seq 1 "${MEASURED_RUNS}"); do
    local tmp; tmp="$(mktemp)"
    if ! /usr/bin/time -l ./gradlew "${TASK}" 2>"$tmp"; then
      echo "WALL=99999 RSS_KB=99999999 GC_PCT=100.0"; rm -f "$tmp"; return
    fi
    local real_s; real_s=$(grep -Eo '([0-9]+\.[0-9]+) real' "$tmp" | awk '{print $1}' || true)
    [ -z "$real_s" ] && real_s=$(grep -i "elapsed" "$tmp" | awk -F'[ms]' '{print ($1/1000)}' || echo 0)
    local rss_kb; rss_kb=$(grep -i "maximum resident set size" "$tmp" | awk '{print $1}' || echo 0)
    rm -f "$tmp"
    total=$(python - <<PY
t=${total}; add=float("${real_s:-0}")
print(round(t+add,3))
PY
)
    if [ "${rss_kb:-0}" -gt "${rss_peak:-0}" ]; then rss_peak="$rss_kb"; fi
  done

  local avg=$(python - <<PY
t=float("${total}"); n=float("${MEASURED_RUNS}")
print(round(t/n,3))
PY
)

  local pauses_ms=$(grep -a "Pause" "${GCLOG_DIR}/gradle-gc-${name}.log" 2>/dev/null | sed -E 's/.* ([0-9]+)ms[),].*/\1/g' | awk '{s+=$1} END{print s+0}')
  local first_s=$(head -n1 "${GCLOG_DIR}/gradle-gc-${name}.log" 2>/dev/null | sed -nE 's/.*\[([0-9]+\.[0-9]+)s\].*/\1/p')
  local last_s=$(tail -n1 "${GCLOG_DIR}/gradle-gc-${name}.log" 2>/dev/null  | sed -nE 's/.*\[([0-9]+\.[0-9]+)s\].*/\1/p')
  local window_ms=$(python - <<PY
try:
  fs=float("${first_s:-0}"); ls=float("${last_s:-0}")
  w=(ls-fs)*1000.0
  print(int(w if w>0 else 1))
except: print(1)
PY
)
  local gc_pct=$(python - <<PY
p=float("${pauses_ms}"); w=float("${window_ms}")
print(round((p/w)*100.0,2))
PY
)
  echo "WALL=${avg} RSS_KB=${rss_peak} GC_PCT=${gc_pct}"
}

best_name=""; best_score=""; best_wall=""; best_rss=""; best_gc=""
best_gr=""; best_kt=""; best_workers=""

idx=1
for tuple in "${CANDIDATES[@]}"; do
  set -- $tuple
  gr="$1"; kt="$2"; wk="$3"
  name="c${idx}_G${gr}_K${kt}_W${wk}"
  echo "== ${name} =="
  metrics=$(measure_case "$name" "$gr" "$kt" "$wk")
  echo "  -> $metrics"
  eval "$metrics"

  score=$(python - <<PY
t=float("${WALL}"); r=float("${RSS_KB}"); g=float("${GC_PCT}")
Wt=float("${W_T}"); Wr=float("${W_R}"); Wg=float("${W_G}")
print(round(Wt*t + Wr*r + Wg*(g/100.0), 4))
PY
)
  echo "  -> score=${score}"

  if [ -z "$best_score" ] || python - <<PY
print(float("${score}") < float("${best_score:-999999}"))
PY
  then
    best_score="$score"; best_name="$name"
    best_wall="$WALL"; best_rss="$RSS_KB"; best_gc="$GC_PCT"
    best_gr="$gr"; best_kt="$kt"; best_workers="$wk"
  fi
  idx=$((idx+1))
done

echo ""
echo "Winner: ${best_name} (score=${best_score})"
echo "  wall=${best_wall}s rss=${best_rss}KB gc=${best_gc}%"
echo "  gradleXmx=${best_gr} kotlinXmx=${best_kt} workers=${best_workers}"

cat > "${JSON_OUT}" <<JSON
{
  "gradleVersionKey": "${GRADLE_VERSION_KEY}",
  "gradleJvmArgs": "-Xms512m -Xmx${best_gr} -XX:+UseG1GC -Dfile.encoding=UTF-8",
  "kotlinDaemonJvmArgs": "-Xms256m -Xmx${best_kt} -XX:+UseG1GC",
  "workersMax": ${best_workers}
}
JSON

echo "Saved ${JSON_OUT}"
echo "Tip: run 'gradle-tune :app:assembleDebug' to tune against your real build."