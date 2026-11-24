[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security
$bundleRoot = Split-Path -Parent $PSScriptRoot
$stateDir = Join-Path $bundleRoot 'state'
$appRoot = Join-Path $bundleRoot 'runtime\app'
$settingsPath = Join-Path $stateDir 'settings.json'
$secretPath = Join-Path $stateDir 'secrets.dpapi'
$runtimePath = Join-Path $bundleRoot 'runtime\local-runtime.mjs'
$nodePath = (Get-Command node.exe -ErrorAction Stop).Source
$nodeVersion = [version]((& $nodePath -p 'process.versions.node').Trim())
if ($nodeVersion -lt [version]'22.12.0') { throw 'Node.js 22.12 or newer is required.' }
if (-not (Test-Path -LiteralPath (Join-Path $appRoot 'build\server\server.js'))) { throw 'The bundled application is missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $appRoot 'node_modules\ws'))) {
    Push-Location $appRoot
    try {
        & npm.cmd ci --omit=dev --ignore-scripts --no-audit --no-fund --registry=https://registry.npmjs.org
        if ($LASTEXITCODE -ne 0) { throw 'Runtime dependency installation failed.' }
    } finally { Pop-Location }
}
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$allowedSids = @($userSid.Value,'S-1-5-18')
& icacls.exe $stateDir /inheritance:r /grant:r ('*' + $userSid.Value + ':(OI)(CI)F') '*S-1-5-18:(OI)(CI)F' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not protect the private state directory.'}
foreach($rule in @((Get-Acl -LiteralPath $stateDir).Access)) {
    $sidValue=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if($sidValue -notin $allowedSids){& icacls.exe $stateDir /remove ('*' + $sidValue) | Out-Null; if($LASTEXITCODE -ne 0){throw 'Could not remove an unexpected state directory permission.'}}
}
if (-not (Test-Path -LiteralPath $settingsPath)) {
    $roots = @((Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Codex'))
    $seedPath = Join-Path $bundleRoot 'config\existing-project-roots.json'
    if (Test-Path -LiteralPath $seedPath) { $roots += @(Get-Content -LiteralPath $seedPath -Raw | ConvertFrom-Json) }
    $settings = [ordered]@{
        port = 3300
        deviceId = 'windows-' + [Guid]::NewGuid().ToString('N')
        deviceLabel = $env:COMPUTERNAME + ' / Codex Desktop'
        allowedRoots = @($roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -Unique)
        codexBin = ''
    }
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
}
if (-not (Test-Path -LiteralPath $secretPath)) {
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 64
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    $plain = [Text.Encoding]::UTF8.GetBytes((@{
        connectorToken = ([BitConverter]::ToString($bytes[0..31]) -replace '-', '').ToLowerInvariant()
        connectorPrivateKey = ([BitConverter]::ToString($bytes[32..63]) -replace '-', '').ToLowerInvariant()
    } | ConvertTo-Json -Compress))
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect($plain, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllText($secretPath, [Convert]::ToBase64String($protected), [Text.UTF8Encoding]::new($false))
    } finally { [Array]::Clear($bytes, 0, $bytes.Length); [Array]::Clear($plain, 0, $plain.Length) }
}
$processPath = Join-Path $stateDir 'process.json'
$alreadyRunning = $false
if (Test-Path -LiteralPath $processPath) {
    $saved = Get-Content -LiteralPath $processPath -Raw | ConvertFrom-Json
    $running = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$saved.pid)" -ErrorAction SilentlyContinue
    $alreadyRunning = $running -and $running.CommandLine -and $running.CommandLine.IndexOf($runtimePath,[StringComparison]::OrdinalIgnoreCase) -ge 0
}
if ($alreadyRunning) {
    throw 'The bridge is already running. Stop it with Ctrl+C in its console, or run scripts\Manage-Remote.ps1 -Action Stop, then run Start.ps1 again.'
}
& (Join-Path $PSScriptRoot 'Apply-Pending-Update.ps1')
& {
    Remove-Item -LiteralPath (Join-Path $stateDir 'stop.request') -Force -ErrorAction SilentlyContinue
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $listener = @(Get-NetTCPConnection -State Listen -LocalPort ([int]$settings.port) -ErrorAction SilentlyContinue)
    if ($listener.Count) { throw 'Port 3300 is occupied. Inspect the listener before starting this bundle.' }
    $nativeCodex = Get-CimInstance Win32_Process -Filter "Name = 'codex.exe'" | Where-Object {
        $_.ExecutablePath -like '*\AppData\Local\OpenAI\Codex\bin\*' -and $_.CommandLine -match 'app-server'
    } | Select-Object -First 1
    if ($nativeCodex) { $settings.codexBin = $nativeCodex.ExecutablePath }
    if (-not $settings.codexBin) { $settings.codexBin = (Get-Command codex.exe -ErrorAction Stop).Source }
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $encrypted = [Convert]::FromBase64String([IO.File]::ReadAllText($secretPath))
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { $secrets = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json } finally { [Array]::Clear($plain, 0, $plain.Length) }
    $names = @('BRIDGE_CONNECTOR_TOKEN','BRIDGE_DEVICE_PRIVATE_KEY','CODEX_REMOTE_STATE_DIR')
    $previous = @{}
    foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        [Environment]::SetEnvironmentVariable('BRIDGE_CONNECTOR_TOKEN', $secrets.connectorToken, 'Process')
        [Environment]::SetEnvironmentVariable('BRIDGE_DEVICE_PRIVATE_KEY', $secrets.connectorPrivateKey, 'Process')
        [Environment]::SetEnvironmentVariable('CODEX_REMOTE_STATE_DIR', $stateDir, 'Process')
        Write-Host 'Starting Codex Remote in this PowerShell window...'
        Write-Host 'Local URL: http://127.0.0.1:3300'
        Write-Host 'Keep this window open. Press Ctrl+C to stop the bridge.'
        Write-Host 'Use a second PowerShell window for setup, pairing and status commands.'
        & $nodePath $runtimePath
        if ($LASTEXITCODE -ne 0) { throw ('Bridge exited with code ' + $LASTEXITCODE + '. See the output above.') }
    } finally {
        # A cancelled native invocation may return before Node has finished stopping.
        # Request shutdown only when this PowerShell process owns the runtime.
        try {
            if (Test-Path -LiteralPath $processPath) {
                $active = Get-Content -LiteralPath $processPath -Raw | ConvertFrom-Json
                $owned = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$active.pid)" -ErrorAction SilentlyContinue
                if ($owned -and $owned.ParentProcessId -eq $PID -and $owned.CommandLine -and $owned.CommandLine.IndexOf($runtimePath,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    [IO.File]::WriteAllText((Join-Path $stateDir 'stop.request'), 'stop')
                    for ($attempt = 0; $attempt -lt 40; $attempt++) {
                        if (-not (Get-Process -Id ([int]$active.pid) -ErrorAction SilentlyContinue)) { break }
                        Start-Sleep -Milliseconds 250
                    }
                }
            }
        } finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
            $secrets = $null
        }
        Write-Host 'Codex Remote stopped. Existing Codex Desktop tasks keep running.'
    }
}
