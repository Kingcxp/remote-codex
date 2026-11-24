[CmdletBinding()]
param([switch]$SkipTests)

$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
$appRoot = Join-Path $bundleRoot 'runtime\app'
$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $npm) { throw 'npm.cmd was not found. Install Node.js 22.12 or later and reopen PowerShell.' }
$node = Get-Command node.exe -ErrorAction Stop
$version = [version]((& $node.Source -p 'process.versions.node').Trim())
if ($version -lt [version]'22.12.0') { throw "Node.js 22.12 or later is required; found $version." }

$processPath = Join-Path $bundleRoot 'state\process.json'
if (Test-Path -LiteralPath $processPath) {
    $record = Get-Content -LiteralPath $processPath -Raw | ConvertFrom-Json
    $runtime = Join-Path $bundleRoot 'runtime\local-runtime.mjs'
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$record.pid)" -ErrorAction SilentlyContinue
    if ($process -and $process.CommandLine -and $process.CommandLine.IndexOf($runtime, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw 'The foreground bridge is running. Stop it in its PowerShell window before rebuilding application files or dependencies.'
    }
}

Push-Location $appRoot
try {
    if (-not (Test-Path -LiteralPath (Join-Path $appRoot 'node_modules\typescript\bin\tsc'))) {
        & $npm.Source ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
    }
    if (-not $SkipTests) {
        & $npm.Source run check
        if ($LASTEXITCODE -ne 0) { throw 'Application type checks or tests failed.' }
    }
    & $npm.Source run build
    if ($LASTEXITCODE -ne 0) { throw 'Application production build failed.' }
    & (Join-Path $PSScriptRoot 'Generate-Third-Party-Notices.ps1')
} finally { Pop-Location }

Write-Host 'Application checks and deployment build completed.' -ForegroundColor Green
