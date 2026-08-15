#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="${FORGE:-forge}"
if ! command -v "$FORGE_BIN" >/dev/null 2>&1 && command -v forge.exe >/dev/null 2>&1; then
  FORGE_BIN="forge.exe"
fi

"$FORGE_BIN" test
bun run test:ts
