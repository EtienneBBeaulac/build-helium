#!/usr/bin/env bash

# timeout command compatible across macOS and Linux
# Usage: with_timeout <seconds> <command...>
with_timeout() {
  local secs="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${secs}" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "${secs}" "$@"
  else
    # Fallback: background watchdog
    ( sleep "${secs}"; echo "[timeout] killing: $*" >&2; pkill -P $$ || true ) &
    local wpid=$!
    "$@"; local rc=$?
    kill "$wpid" >/dev/null 2>&1 || true
    return "$rc"
  fi
}
