#!/usr/bin/env bats

@test "renderers generate md and html" {
  tmp=$(mktemp -d)
  cat > "$tmp/sample.json" <<JSON
{
  "version": "1",
  "generatedAt": "20240101T000000Z",
  "host": {"cpuCores": 8, "ramGB": 16, "os": "Linux", "arch": "x86_64"},
  "gradle": {"version": "8.7", "task": "help"},
  "runs": {"warmups": 0, "measured": 1},
  "weights": {"W_T": 1.0, "W_R": 0.00001, "W_G": 5.0},
  "candidates": [
    {"name": "G4g_K2g_W4", "gradleXmx": "4g", "kotlinXmx": "2g", "workers": 4, "wallSec": 1.2, "rssKB": 1024, "gcPct": 0.1, "score": 1.2}
  ],
  "winner": {"name": "G4g_K2g_W4", "gradleXmx": "4g", "kotlinXmx": "2g", "workers": 4, "wallSec": 1.2, "rssKB": 1024, "gcPct": 0.1, "score": 1.2, "gcReliable": true,
    "flags": {"gradleJvmArgs": "-Xms512m -Xmx4g -XX:+UseG1GC -Dfile.encoding=UTF-8", "kotlinDaemonJvmArgs": "-Xms256m -Xmx2g -XX:+UseG1GC", "workersMax": 4, "useCompressedOops": true}}
}
JSON
  "$BATS_TEST_DIRNAME/../tuner/render_md.sh" "$tmp/sample.json" "$tmp/out.md"
  "$BATS_TEST_DIRNAME/../tuner/render_html.sh" "$tmp/sample.json" "$tmp/out.html"
  [ -s "$tmp/out.md" ]
  [ -s "$tmp/out.html" ]
}


