$ErrorActionPreference = "Stop"

forge fmt --check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$sourceLines = 0
foreach ($sourceFile in Get-ChildItem -Path src -Recurse -Filter *.sol) {
    $sourceLines += @(Get-Content -LiteralPath $sourceFile.FullName).Count
}
Write-Output "Solidity source LOC: $sourceLines"
if ($sourceLines -lt 3800 -or $sourceLines -gt 6500) {
    throw "Expected src/ LOC in range [3800, 6500]"
}

forge build --sizes
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
forge test
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$env:FOUNDRY_PROFILE = "ci"
forge test
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

bun install --frozen-lockfile
bun run format:check
bun run test:ts
bun run verify:repo
