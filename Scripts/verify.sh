#!/bin/bash
# Builds and runs the ground-truth harness against this machine.
# Read-only: it scans and builds uninstall plans, and removes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

MODELS=(ByteFormat SWPItem SafetyPolicy Settings AppInventory OrphanScanner JunkScanner
        StartupScanner InstalledApps ResidueFinder)
SOURCES=()
for model in "${MODELS[@]}"; do SOURCES+=("Sweep/Models/$model.swift"); done

OUT="$(mktemp -d)/sweep-verify"
swiftc -O -o "$OUT" "${SOURCES[@]}" Scripts/verify/main.swift

# `--compile-only` is for CI, which has no representative filesystem to scan.
if [ "${1:-}" = "--compile-only" ]; then
  echo "harness compiles"
  exit 0
fi

"$OUT"
