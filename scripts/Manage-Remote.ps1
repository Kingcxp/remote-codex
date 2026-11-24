[CmdletBinding()]
param(
    [ValidateSet('Status','Pair','Devices','Revoke','Stop')][string]$Action = 'Status',
    [string]$PublicUrl,
    [int]$DeviceIndex
)
$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
$stateDir = Join-Path $bundleRoot 'state'
$settings = Get-Content -LiteralPath (Join-Path $stateDir 'settings.json') -Raw | ConvertFrom-Json
if ($Action -eq 'Stop') {
    [IO.File]::WriteAllText((Join-Path $stateDir 'stop.request'), 'stop')
    Write-Output 'Graceful shutdown requested. Existing Codex Desktop tasks continue running.'
    return
}
$oldRegistry = $env:BRIDGE_DEVICE_REGISTRY_FILE
$oldLanguage = $env:CODEX_UI_LANGUAGE
try {
    $env:BRIDGE_DEVICE_REGISTRY_FILE = Join-Path $stateDir 'devices.json'
    $env:CODEX_UI_LANGUAGE = 'zh-CN'
    $adminScript = Join-Path $bundleRoot 'runtime\app\build\server\device-admin.js'
    if ($Action -eq 'Status') {
        $health = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $settings.port + '/health') -TimeoutSec 3
        $listeners = Get-NetTCPConnection -State Listen -LocalPort ([int]$settings.port) -ErrorAction SilentlyContinue
        [pscustomobject]@{ Healthy = [bool]$health.ok; ListeningAddresses = @($listeners.LocalAddress) } | ConvertTo-Json -Compress
        & node.exe $adminScript list-approved --json
    } elseif ($Action -eq 'Pair') {
        $tailscale = Get-Command tailscale.exe -ErrorAction SilentlyContinue
        $tsPath = if ($tailscale) { $tailscale.Source } else { Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }
        if (-not (Test-Path -LiteralPath $tsPath)) { throw 'Install Tailscale and connect it before pairing a phone or computer.' }
        $statusText = & $tsPath status --json
        if ($LASTEXITCODE -ne 0) { throw 'Could not read Tailscale status. Connect Tailscale first.' }
        $status = $statusText | ConvertFrom-Json
        if ($status.BackendState -ne 'Running') { throw 'Tailscale is disconnected. Connect it before pairing.' }
        $dns = ([string]$status.Self.DNSName).TrimEnd('.')
        if (-not $PublicUrl) { $PublicUrl = 'https://' + $dns }
        if (-not $PublicUrl -or $PublicUrl -notmatch '^https://[a-zA-Z0-9.-]+\.ts\.net/?$') { throw 'Provide the private HTTPS URL, for example -PublicUrl https://codex-host.example-tailnet.ts.net' }
        $PublicUrl = $PublicUrl.TrimEnd('/')
        if (([uri]$PublicUrl).DnsSafeHost -ine $dns) { throw 'The pairing URL must belong to this Windows host in Tailscale.' }
        try { $health = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $settings.port + '/health') -TimeoutSec 3 }
        catch { throw 'The local bridge is not running. Start Start.ps1 in another PowerShell window, then retry Pair.' }
        if (-not $health.ok) { throw 'The local bridge health check failed. Check the Start.ps1 window.' }
        $serveText = & $tsPath serve status --json
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the private HTTPS configuration. Run tailscale serve status.' }
        $serve = $serveText | ConvertFrom-Json
        if ($serve.AllowFunnel -and @($serve.AllowFunnel.PSObject.Properties | Where-Object Value -eq $true).Count) { throw 'Public Funnel is enabled. Disable Funnel before pairing this private service.' }
        $webEntry = if ($serve.Web) { $serve.Web.PSObject.Properties | Where-Object Name -eq ($dns + ':443') | Select-Object -First 1 } else { $null }
        $target = if ($webEntry) { $webEntry.Value.Handlers.'/'.Proxy } else { $null }
        if (-not $serve.TCP.'443'.HTTPS -or $target -ne ('http://127.0.0.1:' + $settings.port)) {
            $configure = Join-Path $PSScriptRoot 'Configure-Private-Access.ps1'
            throw ('Private HTTPS is not configured. Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $configure + '" -ApplyServe. Complete the Tailscale Serve/HTTPS authorization page if prompted, then retry Pair. No pairing link was created.')
        }
        try { $remoteHealth = Invoke-RestMethod -Uri ($PublicUrl + '/health') -TimeoutSec 15 }
        catch { throw ('Private HTTPS could not be reached with a valid certificate: ' + $PublicUrl + '. Check Serve authorization, DNS and connectivity. No pairing link was created. Details: ' + $_.Exception.Message) }
        if (-not $remoteHealth.ok) { throw 'The private HTTPS address is not serving this bridge. No pairing link was created.' }
        Write-Output ('Private HTTPS verified: ' + $PublicUrl)
        & node.exe $adminScript pair $PublicUrl
    } elseif ($Action -eq 'Devices') {
        & node.exe $adminScript list-approved
    } elseif ($Action -eq 'Revoke') {
        if ($DeviceIndex -lt 1) { throw 'Use -DeviceIndex with the index shown by -Action Devices.' }
        & node.exe $adminScript revoke $DeviceIndex
    }
    if ($LASTEXITCODE -ne 0) { throw 'Device administration command failed.' }
} finally {
    $env:BRIDGE_DEVICE_REGISTRY_FILE = $oldRegistry
    $env:CODEX_UI_LANGUAGE = $oldLanguage
}
