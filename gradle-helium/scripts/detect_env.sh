#!/usr/bin/env bash
# Detects CPU cores and RAM (GB) cross-platform

detect_cores() {
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
  else
    nproc
  fi
}

detect_ram_gb() {
  if command -v sysctl >/dev/null 2>&1; then
    echo $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
  else
    echo $(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
  fi
}
