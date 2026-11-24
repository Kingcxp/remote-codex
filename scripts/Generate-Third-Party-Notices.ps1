$ErrorActionPreference = 'Stop'
$appRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\app'
$node = Get-Command node.exe -ErrorAction Stop
$generator = Join-Path $appRoot 'scripts\generate-third-party-notices.mjs'
& $node.Source $generator
if ($LASTEXITCODE -ne 0) { throw 'Could not generate the npm dependency notices.' }
