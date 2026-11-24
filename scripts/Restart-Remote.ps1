[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
$processPath = Join-Path $bundleRoot 'state\process.json'
if (Test-Path -LiteralPath $processPath) {
    $record = Get-Content -LiteralPath $processPath -Raw | ConvertFrom-Json
    $runtime = Join-Path $bundleRoot 'runtime\local-runtime.mjs'
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$record.pid)" -ErrorAction SilentlyContinue
    if ($process -and $process.CommandLine -and $process.CommandLine.IndexOf($runtime,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
        & (Join-Path $PSScriptRoot 'Manage-Remote.ps1') -Action Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        while (Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Bridge shutdown timed out. Press Ctrl+C in its original PowerShell window, then run Start.ps1.' }
            Start-Sleep -Milliseconds 250
        }
    }
}
& (Join-Path $bundleRoot 'Start.ps1')
