#!/usr/bin/env bash
# build-helium — auto-tune Gradle/Kotlin daemon heap & workers, emit JSON/MD/HTML reports
# Usage:
#   helium-tune                     # tune using synthetic heliumBenchmark
#   helium-tune :app:assembleDebug  # tune against a real task
#   helium-tune --help              # flags/help
set -euo pipefail

# ---------- Globals & defaults ----------
export LC_ALL=C LANG=C

PYTHON="python3"
command -v python3 >/dev/null 2>&1 || PYTHON="python"

REPORT_DIR="${HOME}/.gradle/build-helium/reports"
NO_MD=0
NO_HTML=0
JSON_ONLY=0
TAG=""
TASK="heliumBenchmark"              # default synthetic benchmark
WARMUP_RUNS=${WARMUP_RUNS:-1}
MEASURED_RUNS=${MEASURED_RUNS:-2}
W_T=${W_T:-1.0}                        # score weights
W_R=${W_R:-0.00001}
W_G=${W_G:-5.0}
GCLOG_DIR="/tmp/build-helium-gclogs"

# ---------- Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --no-md)      NO_MD=1; shift ;;
    --no-html)    NO_HTML=1; shift ;;
    --json-only)  JSON_ONLY=1; NO_MD=1; NO_HTML=1; shift ;;
    --tag)        TAG="-$2"; shift 2 ;;
    --big)        TASK="heliumBenchmarkBig"; shift ;;
    --help|-h)
      cat <<'HELP'
helium-tune [TASK] [flags]

Without arguments, tunes using "heliumBenchmark" (synthetic heavy task).
You can pass any real Gradle task instead, e.g. ":app:assembleDebug".

Flags:
  --report-dir <dir>   Where to write reports (default ~/.gradle/build-helium/reports)
  --no-md              Skip Markdown report
  --no-html            Skip HTML report
  --json-only          Only write JSON
  --tag <string>       Suffix for report filenames
  --big                Use "heliumBenchmarkBig"

Env overrides:
  W_T W_R W_G          Score weights (time, RSS, GC)
  WARMUP_RUNS          Warmup iterations (default 1)
  MEASURED_RUNS        Measured iterations (default 2)
HELP
      exit 0 ;;
    *) TASK="$1"; shift ;;
  esac
done
[[ -z "${TAG}" ]] && TAG="-$TASK"

# ---------- Sanity checks ----------
if [[ ! -x "./gradlew" ]]; then
  echo "Error: ./gradlew not found. Run helium-tune from a Gradle project root." >&2
  exit 2
fi

detect_time_cmd() {
  if /usr/bin/time -l true >/dev/null 2>&1; then echo "bsd"; return; fi   # macOS bsd time
  if /usr/bin/time -v true >/dev/null 2>&1; then echo "gnu"; return; fi   # GNU time
  echo "none"
}
TIME_KIND="$(detect_time_cmd)"
if [[ "$TIME_KIND" == "none" ]]; then
  echo "Error: need /usr/bin/time supporting -l (macOS) or -v (GNU)." >&2
  exit 1
fi

mkdir -p "$REPORT_DIR" "$GCLOG_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
JSON_OUT="${REPORT_DIR}/report-${STAMP}${TAG}.json"
LATEST_JSON="${REPORT_DIR}/latest.json"

# ---------- Host detection ----------
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
GRADLE_VERSION_KEY="$(./gradlew -v 2>/dev/null | awk '/Gradle /{print $2; exit}' || echo "")"

echo "build-helium: ${CORES} cores, ${RAM_GB} GB RAM"
echo "Task: ${TASK}"

# ---------- Candidate matrix (<32g to keep CompressedOops ON) ----------
declare -a CANDIDATES
if   [ "${RAM_GB}" -ge 64 ]; then
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
echo "Candidates:"; for c in "${CANDIDATES[@]}"; do echo "  $c"; done

# ---------- Helpers ----------
measure_case() {
  local name="$1" gr_xmx="$2" kt_xmx="$3" workers="$4"

  local GR_JVMARGS="-Xms512m -Xmx${gr_xmx} -XX:+UseG1GC -Dfile.encoding=UTF-8 -Xlog:gc*:file=${GCLOG_DIR}/gradle-gc-${name}.log:tags,uptime,level"
  local KT_JVMARGS="-Xms256m -Xmx${kt_xmx} -XX:+UseG1GC -Xlog:gc*:file=${GCLOG_DIR}/kotlin-gc-${name}.log:tags,uptime,level"

  # Override gradle.properties via ORG_GRADLE_PROJECT_* env
  export ORG_GRADLE_PROJECT_org__gradle__jvmargs="${GR_JVMARGS}"
  export ORG_GRADLE_PROJECT_kotlin__daemon__jvmargs="${KT_JVMARGS}"
  export ORG_GRADLE_PROJECT_org__gradle__workers__max="${workers}"

  ./gradlew --stop >/dev/null 2>&1 || true
  [[ -n "${GRADLE_VERSION_KEY}" ]] && rm -rf "${HOME}/.gradle/daemon/${GRADLE_VERSION_KEY}" >/dev/null 2>&1 || true

  # Warmups
  for _ in $(seq 1 "${WARMUP_RUNS}"); do ./gradlew -q "${TASK}" >/dev/null || true; done

  local total=0 rss_peak=0
  for _ in $(seq 1 "${MEASURED_RUNS}"); do
    local tmp; tmp="$(mktemp)"
    set +e
    if [[ "$TIME_KIND" == "bsd" ]]; then
      /usr/bin/time -l ./gradlew "${TASK}" >/dev/null 2>"$tmp"
    else
      /usr/bin/time -v ./gradlew "${TASK}" >/dev/null 2>"$tmp"
    fi
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      rm -f "$tmp"
      echo "WALL=99999 RSS_KB=99999999 GC_PCT=100.0"
      unset ORG_GRADLE_PROJECT_org__gradle__jvmargs ORG_GRADLE_PROJECT_kotlin__daemon__jvmargs ORG_GRADLE_PROJECT_org__gradle__workers__max
      return
    fi

    local real_s rss_kb
    if [[ "$TIME_KIND" == "bsd" ]]; then
      real_s=$(grep -Eo '([0-9]+\.[0-9]+) real' "$tmp" | awk '{print $1}' || true)
      rss_kb=$(grep -i "maximum resident set size" "$tmp" | awk '{print $1}' || echo 0)
    else
      real_s=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$tmp" | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else print $1*60+$2 }')
      rss_kb=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$tmp")
    fi
    rm -f "$tmp"

    total=$("$PYTHON" - <<PY
t=${total}; add=float("${real_s:-0}" or 0)
print(round(t+add,3))
PY
)
    if [[ "${rss_kb:-0}" -gt "${rss_peak:-0}" ]]; then rss_peak="$rss_kb"; fi
  done

  local avg; avg=$("$PYTHON" - <<PY
t=float("${total}"); n=float("${MEASURED_RUNS}")
print(round(t/n,3))
PY
)

  local pauses_ms first_s last_s window_ms gc_pct
  pauses_ms=$(grep -a "Pause" "${GCLOG_DIR}/gradle-gc-${name}.log" 2>/dev/null | sed -E 's/.* ([0-9]+)ms[),].*/\1/g' | awk '{s+=$1} END{print s+0}')
  first_s=$(head -n1 "${GCLOG_DIR}/gradle-gc-${name}.log" 2>/dev/null | sed -nE 's/.*\[([0-9]+\.[0-9]+)s\].*/\1/p')
  last_s=$( tail -n1 "${GCLOG_DIR}/gradle-gc-${name}.log" 2>/dev/null | sed -nE 's/.*\[([0-9]+\.[0-9]+)s\].*/\1/p')
  window_ms=$("$PYTHON" - <<PY
try:
  fs=float("${first_s or 0}"); ls=float("${last_s or 0}")
  w=(ls-fs)*1000.0
  print(int(w if w>0 else 1))
except: print(1)
PY
)
  gc_pct=$("$PYTHON" - <<PY
p=float("${pauses_ms or 0}"); w=float("${window_ms or 1}")
print(round((p/w)*100.0,2))
PY
)

  echo "WALL=${avg} RSS_KB=${rss_peak} GC_PCT=${gc_pct}"

  # Clean env overrides for next candidate
  unset ORG_GRADLE_PROJECT_org__gradle__jvmargs ORG_GRADLE_PROJECT_kotlin__daemon__jvmargs ORG_GRADLE_PROJECT_org__gradle__workers__max
}

# ---------- Main loop ----------
declare -a ROWS
best_name=""; best_score=""; best_wall=""; best_rss=""; best_gc=""
best_gr=""; best_kt=""; best_workers=""
any_success=0

for tuple in "${CANDIDATES[@]}"; do
  set -- $tuple
  gr="$1"; kt="$2"; wk="$3"
  name="G${gr}_K${kt}_W${wk}"
  echo "== ${name} =="

  metrics=$(measure_case "$name" "$gr" "$kt" "$wk")
  echo "  -> $metrics"
  eval "$metrics"

  score=$("$PYTHON" - <<PY
t=float("${WALL}"); r=float("${RSS_KB}"); g=float("${GC_PCT}")
Wt=float("${W_T}"); Wr=float("${W_R}"); Wg=float("${W_G}")
print(round(Wt*t + Wr*r + Wg*(g/100.0), 4))
PY
)
  echo "  -> score=${score}"

  ROWS+=("${name}|${gr}|${kt}|${wk}|${WALL}|${RSS_KB}|${GC_PCT}|${score}")

  # Consider success if WALL not sentinel
  if [[ "$(printf %.0f "${WALL}")" -lt 99999 ]]; then any_success=1; fi

  if [[ -z "$best_score" ]] || "$PYTHON" - <<PY >/dev/null
print(float("${score}") < float("${best_score:-999999}"))
PY
  then
    best_score="$score"; best_name="$name"
    best_wall="$WALL"; best_rss="$RSS_KB"; best_gc="$GC_PCT"
    best_gr="$gr"; best_kt="$kt"; best_workers="$wk"
  fi
done

if [[ "$any_success" == "0" ]]; then
  echo "All candidate runs failed. Check your Gradle task or increase heap." >&2
  exit 3
fi

echo ""
echo "Winner: ${best_name} (score=${best_score})"
echo "  wall=${best_wall}s rss=${best_rss}KB gc=${best_gc}%"
echo "  gradleXmx=${best_gr} kotlinXmx=${best_kt} workers=${best_workers}"

# ---------- Write canonical JSON ----------
"$PYTHON" - <<PY > "$JSON_OUT"
import json, os
rows = ${ROWS@P}
def parse(r):
    n,gx,kx,w,wall,rss,gc,score = r.split("|")
    return dict(name=n, gradleXmx=gx, kotlinXmx=kx, workers=int(w),
                wallSec=float(wall), rssKB=int(float(rss)), gcPct=float(gc), score=float(score))
doc = {
  "version":"1",
  "generatedAt":"${STAMP}",
  "host": {"cpuCores": ${CORES}, "ramGB": ${RAM_GB}, "os": "$(uname -s)", "arch": "$(uname -m)"},
  "gradle": {"version":"${GRADLE_VERSION_KEY:-}", "task":"${TASK}"},
  "runs": {"warmups": ${WARMUP_RUNS}, "measured": ${MEASURED_RUNS}},
  "weights": {"W_T": ${W_T}, "W_R": ${W_R}, "W_G": ${W_G}},
  "candidates": [parse(r) for r in rows],
  "winner": {
      "name":"${best_name}", "gradleXmx":"${best_gr}", "kotlinXmx":"${best_kt}", "workers": ${best_workers},
      "wallSec": ${best_wall}, "rssKB": ${best_rss}, "gcPct": ${best_gc}, "score": ${best_score},
      "flags": {
        "gradleJvmArgs": "-Xms512m -Xmx${best_gr} -XX:+UseG1GC -Dfile.encoding=UTF-8",
        "kotlinDaemonJvmArgs": "-Xms256m -Xmx${best_kt} -XX:+UseG1GC",
        "workersMax": ${best_workers},
        "useCompressedOops": true
      }
  }
}
json.dump(doc, open("${JSON_OUT}", "w"), indent=2)
PY

cp -f "$JSON_OUT" "$LATEST_JSON"
echo "Wrote JSON: $JSON_OUT"

# ---------- Render Markdown & HTML ----------
if [[ "${NO_MD:-0}" != "1" ]]; then
  "$(dirname "$0")/render_md.sh" "$JSON_OUT" "${JSON_OUT%.json}.md"
  cp -f "${JSON_OUT%.json}.md" "${REPORT_DIR}/latest.md"
fi
if [[ "${NO_HTML:-0}" != "1" ]]; then
  "$(dirname "$0")/render_html.sh" "$JSON_OUT" "${JSON_OUT%.json}.html"
  cp -f "${JSON_OUT%.json}.html" "${REPORT_DIR}/latest.html"
fi

echo "Reports in: $REPORT_DIR"
[[ -f "${REPORT_DIR}/latest.html" ]] && echo "Latest HTML: ${REPORT_DIR}/latest.html"
[[ -f "${REPORT_DIR}/latest.md"   ]] && echo "Latest MD:   ${REPORT_DIR}/latest.md"
echo "Tip: run 'helium-tune :app:assembleDebug' to tune against your real build."