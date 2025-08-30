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
GCLOG_BASE="/tmp/build-helium-gclogs"
SHOW_PROGRESS=1
CURRENT_CHILD_PID=""
TIME_CMD=""

# ---------- Signal handling ----------
cleanup_on_signal(){
  stop_spinner || true
  if [[ -n "${CURRENT_CHILD_PID:-}" ]]; then
    kill -INT "${CURRENT_CHILD_PID}" >/dev/null 2>&1 || true
  fi
  echo "\nAborted." >&2
  exit 130
}
trap cleanup_on_signal INT TERM

# ---------- Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --no-md)      NO_MD=1; shift ;;
    --no-html)    NO_HTML=1; shift ;;
    --json-only)  JSON_ONLY=1; NO_MD=1; NO_HTML=1; shift ;;
    --tag)        TAG="-$2"; shift 2 ;;
    --big)        TASK="heliumBenchmarkBig"; shift ;;
    --no-progress) SHOW_PROGRESS=0; shift ;;
    --progress)   SHOW_PROGRESS=1; shift ;;
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
  --progress           Show spinner/progress (default)
  --no-progress        Disable spinner/progress

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

# ---------- Validate/normalize run counts ----------
if [[ "${MEASURED_RUNS}" -lt 1 ]]; then
  echo "Error: MEASURED_RUNS must be >= 1 (got ${MEASURED_RUNS})." >&2
  exit 2
fi
if [[ "${WARMUP_RUNS}" -lt 0 ]]; then
  WARMUP_RUNS=0
fi

# ---------- Sanity checks ----------
if [[ ! -x "./gradlew" ]]; then
  echo "Error: ./gradlew not found. Run helium-tune from a Gradle project root." >&2
  exit 2
fi

detect_time_cmd() {
  if /usr/bin/time -l true >/dev/null 2>&1; then TIME_CMD="/usr/bin/time"; echo "bsd"; return; fi   # macOS bsd time
  if /usr/bin/time -v true >/dev/null 2>&1; then TIME_CMD="/usr/bin/time"; echo "gnu"; return; fi   # GNU time
  if command -v gtime >/dev/null 2>&1; then
    if gtime -v true >/dev/null 2>&1; then TIME_CMD="$(command -v gtime)"; echo "gnu"; return; fi
  fi
  local t
  t="$(command -v time 2>/dev/null || true)"
  if [[ -n "$t" && "$t" != "time" ]]; then
    if "$t" -l true >/dev/null 2>&1; then TIME_CMD="$t"; echo "bsd"; return; fi
    if "$t" -v true >/dev/null 2>&1; then TIME_CMD="$t"; echo "gnu"; return; fi
  fi
  echo "none"
}
TIME_KIND="$(detect_time_cmd)"
if [[ "$TIME_KIND" == "none" ]]; then
  echo "Error: need /usr/bin/time supporting -l (macOS) or -v (GNU)." >&2
  exit 1
fi

mkdir -p "$REPORT_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
JSON_OUT="${REPORT_DIR}/report-${STAMP}${TAG}.json"
LATEST_JSON="${REPORT_DIR}/latest.json"

GCLOG_DIR="${GCLOG_BASE}/${STAMP}"
mkdir -p "$GCLOG_DIR"

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

# Detect Java version (best-effort) to choose compatible GC logging flags
detect_java_major() {
  local line v
  line="$(./gradlew -v 2>/dev/null | grep -m1 '^JVM:' || true)"
  v="$(printf '%s' "$line" | sed -nE 's/.*([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
  if [[ -z "$v" ]]; then
    line="$(java -version 2>&1 | head -n1 || true)"
    v="$(printf '%s' "$line" | sed -nE 's/.*"([0-9]+(\.[0-9]+)?).*/\1/p' | head -n1)"
  fi
  if [[ "$v" == 1.* ]]; then
    echo 8
  else
    echo "${v%%.*}"
  fi
}
JAVA_MAJOR="$(detect_java_major || echo 11)"
case "$JAVA_MAJOR" in ""|*[!0-9]*) JAVA_MAJOR=11;; esac

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

# ---------- Progress UI ----------
spinner_pid=""
start_spinner(){
  [[ "${SHOW_PROGRESS}" != "1" ]] && return
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  (
    i=0
    while :; do
      printf "\r[%s] benchmarking…" "${frames[$((i%10))]}" >&2
      i=$((i+1))
      sleep 0.1
    done
  ) & spinner_pid=$!
}
stop_spinner(){
  [[ -n "${spinner_pid}" ]] && kill "${spinner_pid}" >/dev/null 2>&1 || true
  spinner_pid=""
  [[ "${SHOW_PROGRESS}" == "1" ]] && printf "\r%*s\r" 40 "" >&2
}

# ---------- Helpers ----------
measure_case() {
  local name="$1" gr_xmx="$2" kt_xmx="$3" workers="$4"

  local GC_GRADLE_FLAG GC_KOTLIN_FLAG
  if [[ "${JAVA_MAJOR}" -ge 9 ]]; then
    GC_GRADLE_FLAG="-Xlog:gc*:file=${GCLOG_DIR}/gradle-gc-${name}.log:tags,uptime,level"
    GC_KOTLIN_FLAG="-Xlog:gc*:file=${GCLOG_DIR}/kotlin-gc-${name}.log:tags,uptime,level"
  else
    GC_GRADLE_FLAG="-XX:+PrintGC -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -Xloggc:${GCLOG_DIR}/gradle-gc-${name}.log"
    GC_KOTLIN_FLAG="-XX:+PrintGC -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -Xloggc:${GCLOG_DIR}/kotlin-gc-${name}.log"
  fi
  local GR_JVMARGS="-Xms512m -Xmx${gr_xmx} -XX:+UseG1GC -Dfile.encoding=UTF-8 ${GC_GRADLE_FLAG}"
  local KT_JVMARGS="-Xms256m -Xmx${kt_xmx} -XX:+UseG1GC ${GC_KOTLIN_FLAG}"

  # Create per-run init script to reliably override JVM/worker settings
  local tmp_init; tmp_init="$(mktemp -t helium-init-XXXXXX.gradle.kts)"
  cat > "$tmp_init" <<KTS
gradle.beforeSettings {
  System.setProperty("org.gradle.jvmargs", "${GR_JVMARGS}")
  System.setProperty("kotlin.daemon.jvmargs", "${KT_JVMARGS}")
  System.setProperty("org.gradle.workers.max", "${workers}")
}
KTS

  # Fast test mode: skip real Gradle/time execution
  if [[ "${HELIUM_FAKE_MEASURE:-0}" == "1" ]]; then
    if [[ "${TASK}" == "help" ]]; then
      echo "WALL=1.0 RSS_KB=1024 GC_PCT=0.1 GC_REL=1"
    else
      echo "WALL=99999 RSS_KB=99999999 GC_PCT=100.0 GC_REL=0"
    fi
    rm -f "$tmp_init"
    return
  fi

  ./gradlew --stop >/dev/null 2>&1 || true
  if [[ "${HELIUM_AGGRESSIVE_DAEMON_CLEAN:-0}" == "1" && -n "${GRADLE_VERSION_KEY}" ]]; then
    rm -rf "${HOME}/.gradle/daemon/${GRADLE_VERSION_KEY}" >/dev/null 2>&1 || true
  fi

  # Warmups
  echo "  ~ warmup x${WARMUP_RUNS}" >&2
  for ((i=1; i<=WARMUP_RUNS; i++)); do ./gradlew -I "$tmp_init" -q "${TASK}" >/dev/null || true; done

  local total=0 rss_peak=0
  start_spinner
  for ((i=1; i<=MEASURED_RUNS; i++)); do
    local tmp; tmp="$(mktemp)"
    set +e
    if [[ "$TIME_KIND" == "bsd" ]]; then
      ("$TIME_CMD" -l ./gradlew -I "$tmp_init" "${TASK}" >/dev/null 2>"$tmp") & CURRENT_CHILD_PID=$!; wait "$CURRENT_CHILD_PID"; local rc=$?
    else
      ("$TIME_CMD" -v ./gradlew -I "$tmp_init" "${TASK}" >/dev/null 2>"$tmp") & CURRENT_CHILD_PID=$!; wait "$CURRENT_CHILD_PID"; local rc=$?
    fi
    set -e
    if [[ $rc -ne 0 ]]; then
      rm -f "$tmp"
      stop_spinner
      echo "WALL=99999 RSS_KB=99999999 GC_PCT=100.0"
      rm -f "$tmp_init"
      return
    fi

    local real_s rss_kb
    if [[ "$TIME_KIND" == "bsd" ]]; then
      real_s=$(grep -Eo '([0-9]+\.[0-9]+) real' "$tmp" | awk '{print $1}' || true)
      rss_kb=$(sed -nE 's/.*[Mm]aximum resident set size[^0-9]*([0-9]+).*/\1/p' "$tmp" | head -n1)
    else
      real_s=$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "$tmp" | awk -F: '{ if (NF==3) print $1*3600+$2*60+$3; else print $1*60+$2 }')
      rss_kb=$(awk -F': ' '/Maximum resident set size/ {print $2}' "$tmp" | tr -dc '0-9')
    fi
    [[ -z "${rss_kb:-}" ]] && rss_kb=0
    rm -f "$tmp"

    total=$("$PYTHON" - <<'PY' "${total}" "${real_s:-0}"
import sys
try:
    t = float(sys.argv[1])
except Exception:
    t = 0.0
try:
    add = float(sys.argv[2])
except Exception:
    add = 0.0
print(round(t + add, 3))
PY
)
    if [[ "${rss_kb:-0}" -gt "${rss_peak:-0}" ]]; then rss_peak="$rss_kb"; fi
  done
  stop_spinner

  local avg; avg=$("$PYTHON" - <<'PY' "${total}" "${MEASURED_RUNS}"
import sys
try:
    t = float(sys.argv[1])
    n = float(sys.argv[2])
    print(round(t/n, 3))
except Exception:
    print(0.0)
PY
)

  local pauses_ms first_s last_s window_ms gc_pct
  pauses_ms=$(grep -a "Pause" "${GCLOG_DIR}/gradle-gc-${name}.log" 2>/dev/null | sed -E 's/.* ([0-9]+)ms[),].*/\1/g' | awk '{s+=$1} END{print s+0}')
  first_s=$(head -n1 "${GCLOG_DIR}/gradle-gc-${name}.log" 2>/dev/null | sed -nE 's/.*\[([0-9]+\.[0-9]+)s\].*/\1/p')
  last_s=$( tail -n1 "${GCLOG_DIR}/gradle-gc-${name}.log" 2>/dev/null | sed -nE 's/.*\[([0-9]+\.[0-9]+)s\].*/\1/p')
  window_ms=$("$PYTHON" - <<'PY' "${first_s:-0}" "${last_s:-0}"
import sys
try:
    fs = float(sys.argv[1])
    ls = float(sys.argv[2])
    w = (ls - fs) * 1000.0
    print(int(w if w > 0 else 1))
except Exception:
    print(1)
PY
)
  gc_pct=$("$PYTHON" - <<'PY' "${pauses_ms:-0}" "${window_ms:-1}"
import sys
try:
    p = float(sys.argv[1])
    w = float(sys.argv[2])
    print(round((p / (w if w != 0 else 1)) * 100.0, 2))
except Exception:
    print(0.0)
PY
)

  local gc_rel; gc_rel=$("$PYTHON" - <<'PY' "${first_s:-0}" "${last_s:-0}"
import sys
try:
    fs = float(sys.argv[1])
    ls = float(sys.argv[2])
    print(1 if ls > fs else 0)
except Exception:
    print(0)
PY
)

  echo "WALL=${avg} RSS_KB=${rss_peak} GC_PCT=${gc_pct} GC_REL=${gc_rel}"

  # Clean per-run init
  rm -f "$tmp_init"
}

# ---------- Main loop ----------
declare -a ROWS
best_name=""; best_score=""; best_wall=""; best_rss=""; best_gc=""
best_gr=""; best_kt=""; best_workers=""; best_gcrel="1"
any_success=0

for tuple in "${CANDIDATES[@]}"; do
  set -- $tuple
  gr="$1"; kt="$2"; wk="$3"
  name="G${gr}_K${kt}_W${wk}"
  echo "== ${name} =="

  metrics=$(measure_case "$name" "$gr" "$kt" "$wk")
  echo "  -> $metrics"
  eval "$metrics"

  score=$("$PYTHON" - <<'PY' "${WALL}" "${RSS_KB}" "${GC_PCT}" "${W_T}" "${W_R}" "${W_G}"
import sys
try:
    t = float(sys.argv[1]); r = float(sys.argv[2]); g = float(sys.argv[3])
    Wt = float(sys.argv[4]); Wr = float(sys.argv[5]); Wg = float(sys.argv[6])
    print(round(Wt*t + Wr*r + Wg*(g/100.0), 4))
except Exception:
    print(9e9)
PY
)
  echo "  -> score=${score}"

  ROWS+=("${name}|${gr}|${kt}|${wk}|${WALL}|${RSS_KB}|${GC_PCT}|${score}|${GC_REL}")

  # Consider success if WALL not sentinel
  if [[ "$(printf %.0f "${WALL}")" -lt 99999 ]]; then any_success=1; fi

  if [[ -z "$best_score" ]] || "$PYTHON" - <<PY >/dev/null
print(float("${score}") < float("${best_score:-999999}"))
PY
  then
    best_score="$score"; best_name="$name"
    best_wall="$WALL"; best_rss="$RSS_KB"; best_gc="$GC_PCT"
    best_gr="$gr"; best_kt="$kt"; best_workers="$wk"; best_gcrel="$GC_REL"
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
{
  printf '%s\n' "${ROWS[@]}" | "$PYTHON" - <<'PY' "${JSON_OUT}" "${STAMP}" "${CORES}" "${RAM_GB}" "${GRADLE_VERSION_KEY:-}" "${TASK}" "${WARMUP_RUNS}" "${MEASURED_RUNS}" "${W_T}" "${W_R}" "${W_G}" "${best_name}" "${best_gr}" "${best_kt}" "${best_workers}" "${best_wall}" "${best_rss}" "${best_gc}" "${best_score}" "${best_gcrel}"
import sys, json, os

out_path = sys.argv[1]
STAMP, CORES, RAM_GB = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
GRADLE_VERSION_KEY, TASK = sys.argv[5], sys.argv[6]
WARMUPS, MEASURED = int(sys.argv[7]), int(sys.argv[8])
W_T, W_R, W_G = float(sys.argv[9]), float(sys.argv[10]), float(sys.argv[11])
best_name, best_gr, best_kt = sys.argv[12], sys.argv[13], sys.argv[14]
best_workers = int(sys.argv[15])
best_wall, best_rss, best_gc = float(sys.argv[16]), int(float(sys.argv[17])), float(sys.argv[18])
best_score = float(sys.argv[19])
best_gcrel = sys.argv[20]

rows = sys.stdin.read().splitlines()
def parse(r):
    n,gx,kx,w,wall,rss,gc,score,gcrel = r.split('|')
    return dict(name=n, gradleXmx=gx, kotlinXmx=kx, workers=int(w),
                wallSec=float(wall), rssKB=int(float(rss)), gcPct=float(gc), score=float(score), gcReliable=(gcrel=='1'))

doc = {
  "version": "1",
  "generatedAt": STAMP,
  "host": {"cpuCores": CORES, "ramGB": RAM_GB, "os": os.uname().sysname, "arch": os.uname().machine},
  "gradle": {"version": GRADLE_VERSION_KEY, "task": TASK},
  "runs": {"warmups": WARMUPS, "measured": MEASURED},
  "weights": {"W_T": W_T, "W_R": W_R, "W_G": W_G},
  "candidates": [parse(r) for r in rows if r.strip()],
  "winner": {
      "name": best_name, "gradleXmx": best_gr, "kotlinXmx": best_kt, "workers": best_workers,
      "wallSec": best_wall, "rssKB": best_rss, "gcPct": best_gc, "score": best_score, "gcReliable": (best_gcrel=='1'),
      "flags": {
        "gradleJvmArgs": f"-Xms512m -Xmx{best_gr} -XX:+UseG1GC -Dfile.encoding=UTF-8",
        "kotlinDaemonJvmArgs": f"-Xms256m -Xmx{best_kt} -XX:+UseG1GC",
        "workersMax": best_workers,
        "useCompressedOops": True
      }
  }
}

with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(doc, f, indent=2)
PY
}

cp -f "$JSON_OUT" "$LATEST_JSON"
echo "Wrote JSON: $JSON_OUT"

# ---------- Persist winner to ~/.gradle/gradle-tuner.json ----------
CFG_PATH="${HOME}/.gradle/gradle-tuner.json"
tmp_cfg="$(mktemp)"
"$PYTHON" - <<PY > "$tmp_cfg"
import json, os, sys
cfg_path = os.path.expanduser("${CFG_PATH}")
try:
  existing = json.load(open(cfg_path))
except Exception:
  existing = {}
existing.update({
  "gradleVersionKey": "${GRADLE_VERSION_KEY}",
  "gradleJvmArgs": f"-Xms512m -Xmx${best_gr} -XX:+UseG1GC -Dfile.encoding=UTF-8",
  "kotlinDaemonJvmArgs": f"-Xms256m -Xmx${best_kt} -XX:+UseG1GC",
  "workersMax": int(${best_workers})
})
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
with open(cfg_path+".bak", "w") as b:
  try:
    json.dump(existing, b, indent=2)
  except Exception:
    pass
json.dump(existing, open(cfg_path, "w"), indent=2)
print(cfg_path)
PY
echo "Persisted tuned config to: $CFG_PATH"

# ---------- Render Markdown & HTML ----------
if [[ "${NO_MD:-0}" != "1" ]]; then
  if command -v build-helium-render-md >/dev/null 2>&1; then
    build-helium-render-md "$JSON_OUT" "${JSON_OUT%.json}.md"
  else
    "$(dirname "$0")/render_md.sh" "$JSON_OUT" "${JSON_OUT%.json}.md"
  fi
  cp -f "${JSON_OUT%.json}.md" "${REPORT_DIR}/latest.md"
fi
if [[ "${NO_HTML:-0}" != "1" ]]; then
  if command -v build-helium-render-html >/dev/null 2>&1; then
    build-helium-render-html "$JSON_OUT" "${JSON_OUT%.json}.html"
  else
    "$(dirname "$0")/render_html.sh" "$JSON_OUT" "${JSON_OUT%.json}.html"
  fi
  cp -f "${JSON_OUT%.json}.html" "${REPORT_DIR}/latest.html"
fi

echo "Reports in: $REPORT_DIR"
[[ -f "${REPORT_DIR}/latest.html" ]] && echo "Latest HTML: ${REPORT_DIR}/latest.html"
[[ -f "${REPORT_DIR}/latest.md"   ]] && echo "Latest MD:   ${REPORT_DIR}/latest.md"
echo "Tip: run 'helium-tune :app:assembleDebug' to tune against your real build."

# Optional: cleanup per-session GC logs (set KEEP_GCLOGS=1 to retain)
if [[ "${KEEP_GCLOGS:-0}" != "1" ]]; then
  rm -rf "$GCLOG_DIR" >/dev/null 2>&1 || true
fi