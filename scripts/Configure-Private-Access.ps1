[CmdletBinding()]
param([string]$ArchIP, [string]$AndroidIP, [switch]$ApplyServe, [switch]$IncludeRustDesk)
$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
if (($ArchIP -or $AndroidIP) -and (Test-Path -LiteralPath (Join-Path $bundleRoot 'state\access-devices.json'))) { throw 'A multi-device profile exists. Use Setup.ps1 -Action Policy to preserve its full access list. -ApplyServe without the old device IP arguments remains supported.' }
function Assert-TailscaleIP([string]$Value) {
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or $parsed.AddressFamily -ne 'InterNetwork') { throw 'Use a single Tailscale IPv4 address for each device.' }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes[0] -ne 100 -or $bytes[1] -lt 64 -or $bytes[1] -gt 127) { throw 'The address must be in the Tailscale 100.64.0.0/10 range.' }
}
$ts = Get-Command tailscale.exe -ErrorAction SilentlyContinue
$tsPath = if ($ts) { $ts.Source } else { Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }
if (-not (Test-Path -LiteralPath $tsPath)) { throw 'Install Tailscale from https://tailscale.com/download/windows and sign in first.' }
$statusText = & $tsPath status --json
if ($LASTEXITCODE -ne 0) { throw 'Tailscale is not ready. Sign in using its Windows app.' }
$status = $statusText | ConvertFrom-Json
if ($status.BackendState -ne 'Running') { throw 'Tailscale must be connected before configuring Serve.' }
$windowsIP = @($status.TailscaleIPs | Where-Object { $_ -match '^100\.' })[0]
Assert-TailscaleIP $windowsIP
$dns = ([string]$status.Self.DNSName).TrimEnd('.')
if ($dns -notmatch '^[a-zA-Z0-9.-]+\.ts\.net$') { throw 'Enable MagicDNS in the Tailscale admin console first.' }
$url = 'https://' + $dns
if ($ArchIP -or $AndroidIP) {
    if (-not $ArchIP -or -not $AndroidIP) { throw 'Provide both -ArchIP and -AndroidIP to generate the complete access policy.' }
    Assert-TailscaleIP $ArchIP; Assert-TailscaleIP $AndroidIP
    if (@($windowsIP,$ArchIP,$AndroidIP | Select-Object -Unique).Count -ne 3) { throw 'Each of the three devices must have a different IP.' }
    $policyPath = Join-Path $bundleRoot 'config\tailnet-policy.generated.json'
    # Preserve the locally requested RustDesk grant when regenerating for a replacement Linux device.
    $keepRustDesk = [bool]$IncludeRustDesk
    if (Test-Path -LiteralPath $policyPath) {
        $previousPolicy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
        if (@($previousPolicy.grants | Where-Object { $_.ip -contains 'tcp:21118' }).Count) { $keepRustDesk = $true }
    }
    $archPorts = @('tcp:22', 'tcp:443')
    $androidPorts = @('tcp:443')
    $archAccept = @('codex-windows:22', 'codex-windows:443')
    $androidAccept = @('codex-windows:443')
    if ($keepRustDesk) {
        $archPorts += 'tcp:21118'; $androidPorts += 'tcp:21118'
        $archAccept += 'codex-windows:21118'; $androidAccept += 'codex-windows:21118'
    }
    $policy = [ordered]@{
        hosts = [ordered]@{'codex-windows'=$windowsIP; 'codex-arch'=$ArchIP; 'codex-android'=$AndroidIP}
        grants = @(
            [ordered]@{src=@('codex-arch'); dst=@('codex-windows'); ip=$archPorts},
            [ordered]@{src=@('codex-android'); dst=@('codex-windows'); ip=$androidPorts}
        )
        tests = @(
            [ordered]@{src=$ArchIP; accept=$archAccept; deny=@('codex-windows:3300')},
            [ordered]@{src=$AndroidIP; accept=$androidAccept; deny=@('codex-windows:22','codex-windows:3300')}
        )
    }
    [IO.File]::WriteAllText($policyPath, ($policy | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    Write-Output ('Access policy written: ' + $policyPath)
    Write-Output 'Review it in https://login.tailscale.com/admin/acls. On a fresh dedicated tailnet, replace the default allow-all policy with it; do not append it alongside allow-all rules.'
}
Write-Output ('Windows Tailscale IPv4: ' + $windowsIP)
Write-Output ('Private Codex URL: ' + $url)
if (-not $ApplyServe) {
    Write-Output 'Preview only. Add -ApplyServe to enable private HTTPS after reviewing the tailnet policy.'
    return
}
$health = Invoke-RestMethod http://127.0.0.1:3300/health -TimeoutSec 3
if (-not $health.ok) { throw 'Start the local bridge with Start.ps1 in another PowerShell window first.' }
$serveText = & $tsPath serve status --json
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect existing Serve configuration.' }
$existing = $serveText | ConvertFrom-Json
$funnelEnabled = $existing.AllowFunnel -and @($existing.AllowFunnel.PSObject.Properties | Where-Object Value -eq $true).Count -gt 0
if($funnelEnabled){throw 'Funnel is enabled. Disable that public exposure in Tailscale before configuring this private service.'}
$existingProperties = @($existing.PSObject.Properties | Where-Object { $_.Value -and $_.Name -notin @('AllowFunnel','ETag') })
if ($existingProperties.Count) {
    $web = $existing.Web
    $target = $null
    if ($web) { $entry = $web.PSObject.Properties | Where-Object Name -eq ($dns + ':443') | Select-Object -First 1; if ($entry) { $target = $entry.Value.Handlers.'/'.Proxy } }
    $funnel = $existing.AllowFunnel
    $funnelEnabled = $funnel -and @($funnel.PSObject.Properties | Where-Object Value -eq $true).Count -gt 0
    if ($target -eq 'http://127.0.0.1:3300' -and -not $funnelEnabled) { Write-Output 'The desired private Serve route already exists.'; & $tsPath serve status; return }
    throw 'Existing Serve/Funnel configuration detected. Review tailscale serve status before changing it. This script will not overwrite it.'
}
& $tsPath serve --bg --https=443 http://127.0.0.1:3300
if ($LASTEXITCODE -ne 0) { throw 'Serve was not enabled. Follow the HTTPS authorization link printed by Tailscale, then run this command again.' }
& $tsPath serve status
if ($LASTEXITCODE -ne 0) { throw 'Serve status verification failed.' }
Write-Output ('Next: .\scripts\Manage-Remote.ps1 -Action Pair -PublicUrl ' + $url)
