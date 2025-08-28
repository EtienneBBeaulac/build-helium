#!/usr/bin/env bash
# Simple GC log parser for gradle-sweetspot

parse_gc_log() {
  local file="$1"
  grep -a "Pause" "$file" | sed -E 's/.* ([0-9]+)ms[),].*/\1/g' | awk '{s+=$1} END{print s+0}'
}

# Usage: parse_gc_log /path/to/gc.log
