#!/usr/bin/env bash
set -euo pipefail
IN="$1"; OUT="${2:-${IN%.json}.html}"

PYTHON="python3"
command -v python3 >/dev/null 2>&1 || PYTHON="python"

"$PYTHON" - <<'PY' "$IN" "$OUT"
import json, sys
from html import escape

inp, out = sys.argv[1], sys.argv[2]
with open(inp, "r", encoding="utf-8") as f:
    d = json.load(f)

def gb(kb):
    try:
        return f"{int(kb)/1048576:.2f} GB"
    except Exception:
        return "—"

h = d.get('host', {})
g = d.get('gradle', {})
w = d.get('winner', {})
candidates = d.get('candidates', [])

# Defensive: coerce/format numbers nicely
def fmt(v, nd=1):
    try:
        return f"{float(v):.{nd}f}"
    except Exception:
        return "—"

# Stable sort by score (if present)
def score_key(c): 
    try:
        return float(c.get('score', 9e9))
    except Exception:
        return 9e9
candidates = sorted(candidates, key=score_key)

winner_name = w.get('name', '')
def row(c):
    win = (c.get('name') == winner_name)
    mark = ' class="win"' if win else ''
    name = escape(str(c.get('name','')))
    gx = escape(str(c.get('gradleXmx','')))
    kx = escape(str(c.get('kotlinXmx','')))
    wk = escape(str(c.get('workers','')))
    wall = fmt(c.get('wallSec'))
    rss = gb(c.get('rssKB', 0))
    gc = fmt(c.get('gcPct'), 1)
    score = fmt(c.get('score'), 1)
    if win: name = f"<strong>{name}</strong>"
    return f"""<tr{mark}>
<td>{name}</td><td>{gx}</td><td>{kx}</td><td>{wk}</td>
<td>{wall}</td><td>{rss}</td><td>{gc}%</td><td>{score}</td>
</tr>"""

rows = "\n".join(row(c) for c in candidates)

date = escape(str(d.get('generatedAt','')))
host = f"{escape(str(h.get('os','')))} {escape(str(h.get('arch','')))} · {escape(str(h.get('ramGB','')))} GB · {escape(str(h.get('cpuCores','')))} cores"
gradle = escape(str(g.get('version','')))
task = escape(str(g.get('task','')))
w_wall = fmt(w.get('wallSec'))
w_rss = gb(w.get('rssKB', 0))
w_gc  = fmt(w.get('gcPct'), 1)
w_score = fmt(w.get('score'), 1)
w_name = escape(winner_name)
gcr = w.get('gcReliable', True)
gcn = " (GC% may be unreliable)" if not gcr else ""

wf = w.get('flags', {})
gradle_args = escape(str(wf.get('gradleJvmArgs','')))
kotlin_args = escape(str(wf.get('kotlinDaemonJvmArgs','')))
workers_max = escape(str(wf.get('workersMax','')))
oops = escape(str(wf.get('useCompressedOops','')))

W_T = d.get('weights',{}).get('W_T','1.0')
W_R = d.get('weights',{}).get('W_R','0.00001')
W_G = d.get('weights',{}).get('W_G','5.0')

html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>build-helium — Benchmark Report</title>
<style>
:root {{ --ok:#10b981; --muted:#6b7280; --bg:#0b1020; --card:#111827; --fg:#e5e7eb; }}
@media (prefers-color-scheme: light) {{
  :root {{ --bg:#f8fafc; --card:#ffffff; --fg:#111827; --muted:#64748b; }}
}}
body{{margin:0;font:14px/1.5 system-ui,-apple-system,Segoe UI,Roboto,Ubuntu;background:var(--bg);color:var(--fg)}}
.wrap{{max-width:980px;margin:40px auto;padding:0 16px}}
.h1{{font-size:28px;font-weight:700;margin-bottom:8px}}
.muted{{color:var(--muted)}}
.card{{background:var(--card);border-radius:14px;padding:18px;margin:18px 0;box-shadow:0 8px 24px rgba(0,0,0,.08)}}
table{{width:100%;border-collapse:collapse}}
th,td{{padding:10px 12px;border-bottom:1px solid rgba(0,0,0,.08);text-align:right;vertical-align:top}}
th:first-child,td:first-child{{text-align:left}}
tr.win{{background:linear-gradient(90deg, rgba(16,185,129,.12), rgba(16,185,129,0))}}
.badge{{display:inline-block;padding:4px 10px;border-radius:999px;font-weight:600;font-size:12px;
background:rgba(16,185,129,.2);color:#065f46;border:1px solid rgba(16,185,129,.35)}}
code{{background:rgba(0,0,0,.06);padding:2px 6px;border-radius:6px}}
pre{{background:rgba(0,0,0,.06);padding:10px 12px;border-radius:10px;overflow:auto}}
.footer{{margin:16px 0 40px}}
a{{color:#3b82f6;text-decoration:none}}
a:hover{{text-decoration:underline}}
</style>
</head>
<body>
<div class="wrap">
  <div class="h1">build-helium — Benchmark Report</div>
  <div class="muted">Date: {date} • Host: {host} • Gradle {gradle} • Task: <code>{task}</code></div>

  <div class="card">
    <div><strong>Winner</strong>: <span class="badge">{w_name}</span> &nbsp; 
      <strong>Wall</strong> {w_wall} s &nbsp; 
      <strong>Peak RSS</strong> {w_rss} &nbsp; 
      <strong>GC</strong> {w_gc}%{gcn} &nbsp; 
      <strong>Score</strong> {w_score}</div>
  </div>

  <div class="card">
    <h3>Summary</h3>
    <table>
      <thead>
        <tr>
          <th>Candidate</th><th>Gradle Xmx</th><th>Kotlin Xmx</th><th>Workers</th>
          <th>Wall (s)</th><th>Peak RSS</th><th>GC %</th><th>Score</th>
        </tr>
      </thead>
      <tbody>
        {rows}
      </tbody>
    </table>
    <p class="muted" style="margin-top:8px">Score = time × {W_T} + RSSKB × {W_R} + (GC%/100) × {W_G}</p>
  </div>

  <div class="card">
    <h3>Daemon Flags (winner)</h3>
    <pre><code>Gradle: {gradle_args}
Kotlin: {kotlin_args}
Workers: {workers_max}
CompressedOops: {oops}</code></pre>
  </div>

  <div class="footer muted">
    Source JSON: <code>{escape(inp)}</code>
  </div>
</div>
</body>
</html>"""

with open(out, "w", encoding="utf-8") as f:
    f.write(html)
print(f"HTML report: {out}")
PY