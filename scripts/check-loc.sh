#!/usr/bin/env bash
set -euo pipefail

MIN_LOC="${MIN_SRC_LOC:-3800}"
MAX_LOC="${MAX_SRC_LOC:-6500}"

TOTAL="$(find src -type f -name '*.sol' -print0 | xargs -0 wc -l | tail -n 1 | awk '{print $1}')"

echo "Solidity source LOC: $TOTAL"

if [ "$TOTAL" -lt "$MIN_LOC" ] || [ "$TOTAL" -gt "$MAX_LOC" ]; then
  echo "Expected src/ LOC in range [$MIN_LOC, $MAX_LOC]" >&2
  exit 1
fi
