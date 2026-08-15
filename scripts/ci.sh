#!/usr/bin/env bash
set -euo pipefail

FORGE_BIN="${FORGE:-forge}"
if ! command -v "$FORGE_BIN" >/dev/null 2>&1 && command -v forge.exe >/dev/null 2>&1; then
  FORGE_BIN="forge.exe"
fi

"$FORGE_BIN" fmt --check
bash scripts/check-loc.sh
"$FORGE_BIN" build --sizes
"$FORGE_BIN" test
FOUNDRY_PROFILE=ci "$FORGE_BIN" test
bun install --frozen-lockfile
bun run format:check
bun run test:ts
bun run verify:repo
