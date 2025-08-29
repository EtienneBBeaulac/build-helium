#!/usr/bin/env bash
set -euo pipefail
IN="$1"; OUT="${2:-${IN%.json}.md}"

PYTHON="python3"
command -v python3 >/dev/null 2>&1 || PYTHON="python"

"$PYTHON" - <<'PY' "$IN" "$OUT"
import json, sys, re
inp, out = sys.argv[1], sys.argv[2]
with open(inp, "r", encoding="utf-8") as f:
    d = json.load(f)

def gb(kb):
    try:
        return f"{int(kb)/1048576:.2f} GB"
    except Exception:
        return "—"

def fmt(v, nd=1):
    try:
        return f"{float(v):.{nd}f}"
    except Exception:
        return "—"

# Escape backticks inside code spans
def code(s: str) -> str:
    s = str(s)
    return s.replace("`", "\\`")

h = d.get('host', {})
g = d.get('gradle', {})
w = d.get('winner', {})
candidates = d.get('candidates', [])
weights = d.get('weights', {})

# Sort candidates by score (if present)
def score_key(c):
    try: return float(c.get('score', 9e9))
    except Exception: return 9e9
candidates = sorted(candidates, key=score_key)

lines = []
lines += [f"# build-helium — Benchmark Report\n"]
lines += [f"**Date:** {d.get('generatedAt','')}  "]
lines += [f"**Host:** {h.get('os','')} {h.get('arch','')} • {h.get('ramGB','')} GB • {h.get('cpuCores','')} cores  "]
lines += [f"**Gradle:** {g.get('version','')} • **Task:** `{code(g.get('task',''))}`  "]
runs = d.get('runs', {})
lines += [f"**Runs:** warmup ×{runs.get('warmups','?')}, measured ×{runs.get('measured','?')}\n"]

winner_name = w.get('name','')
lines += [f"> **Winner:** `{code(winner_name)}` — fastest with reasonable memory and low GC\n"]

lines += ["## Summary\n",
          "| Candidate | Gradle Xmx | Kotlin Xmx | Workers | Wall (s) | Peak RSS | GC % | Score |",
          "|-----------|------------|------------|---------|----------|---------:|-----:|------:|"]

for c in candidates:
    is_win = (c.get('name') == winner_name)
    mark  = "**" if is_win else ""
    name  = f"{mark}`{code(c.get('name',''))}`{mark}"
    gx    = f"{mark}{c.get('gradleXmx','')}{mark}"
    kx    = f"{mark}{c.get('kotlinXmx','')}{mark}"
    wk    = f"{mark}{c.get('workers','')}{mark}"
    wall  = f"{mark}{fmt(c.get('wallSec'),1)}{mark}"
    rss   = f"{mark}{gb(c.get('rssKB',0))}{mark}"
    gc    = f"{mark}{fmt(c.get('gcPct'),1)}%{mark}"
    score = f"{mark}{fmt(c.get('score'),1)}{mark}"
    lines += [f"| {name} | {gx} | {kx} | {wk} | {wall} | {rss} | {gc} | {score} |"]

WT = weights.get('W_T','1.0'); WR = weights.get('W_R','0.00001'); WG = weights.get('W_G','5.0')
lines += [f"\n**Scoring:** `time*{WT} + RSS_KB*{WR} + (GC%/100)*{WG}` (lower is better)\n"]

wf = w.get('flags', {})
lines += ["## Daemon flags (winner)\n", "```",
          f"Gradle: {wf.get('gradleJvmArgs','')}",
          f"Kotlin: {wf.get('kotlinDaemonJvmArgs','')}",
          f"Workers: {wf.get('workersMax','')}",
          f"CompressedOops: {w.get('flags',{}).get('useCompressedOops','')}",
          "```", ""]

# Tiny footer to the source JSON
lines += [f"<sub>Source JSON: `{code(inp)}`</sub>\n"]

with open(out,"w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print(f"Markdown report: {out}")
PY