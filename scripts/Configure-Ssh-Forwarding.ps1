[CmdletBinding()]
param(
    [string]$PveIP,
    [string]$ClientIP = '127.0.0.1',
    [string]$SshUser = $env:USERNAME,
    [switch]$Apply,
    [string]$RestoreFrom
)
$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
$backupRoot = Join-Path $env:ProgramData 'CodexPrivateSSH\forwarding-backups'
$resultPath = Join-Path $bundleRoot 'state\ssh-forwarding-result.json'

function Get-ForwardingConfig([string]$Text, [string]$Address) {
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed) -or $parsed.AddressFamily -ne 'InterNetwork' -or $parsed.ToString() -ne $Address) {
        throw 'PveIP must be a single, canonical IPv4 address.'
    }
    if ($Text -notmatch '(?m)^# Managed by Codex Remote Access\.') { throw 'This helper only updates the SSH configuration created by this deployment.' }
    if ($Text -match '(?im)^[\t ]*(Match|Include)(?:[\t ]|=)') { throw 'Match/Include directives require manual review before updating forwarding.' }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $settings = [ordered]@{
        DisableForwarding = 'no'
        AllowTcpForwarding = 'local'
        PermitOpen = ('localhost:* 127.0.0.1:* [::1]:* ' + $Address + ':8006')
        PermitListen = 'none'
        GatewayPorts = 'no'
        AllowAgentForwarding = 'no'
    }
    $updated = [regex]::Replace($Text,'(?im)^# Forwarding policy managed by Configure-Ssh-Forwarding\.ps1\r?\n','')
    foreach ($name in $settings.Keys) {
        $pattern = '(?im)^[\t ]*' + [regex]::Escape($name) + '(?:[\t ]+|=)[^\r\n]*(?:\r?\n|$)'
        $updated = [regex]::Replace($updated,$pattern,'')
    }
    $prefix = @('# Forwarding policy managed by Configure-Ssh-Forwarding.ps1')
    foreach ($name in $settings.Keys) { $prefix += ($name + ' ' + $settings[$name]) }
    return ($prefix -join $newline) + $newline + $updated.TrimEnd() + $newline
}
function Get-EffectiveForwarding([string]$Sshd, [string]$Path, [string]$User, [string]$ClientAddress) {
    $lines = @(& $Sshd -T -f $Path -C "user=$User,host=localhost,addr=$ClientAddress" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ('Could not inspect effective SSH settings: ' + ($lines -join ' ')) }
    $values = @{}
    foreach ($line in $lines) {
        $pair = ([string]$line) -split '\s+',2
        if ($pair.Count -eq 2) { $values[$pair[0]] = $pair[1] }
    }
    return $values
}
function Protect-Backup([string]$Path) {
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not protect the SSH backup directory.' }
    foreach ($rule in @((Get-Acl -LiteralPath $Path).Access)) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -notin @('S-1-5-18','S-1-5-32-544')) {
            & icacls.exe $Path /remove ('*' + $sid) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not restrict SSH backup access.' }
        }
    }
}
if (-not $RestoreFrom) {
    if (-not $PveIP) { throw 'Provide -PveIP for the single PVE host that SSH may forward to.' }
    $parsedPve = $null
    if (-not [Net.IPAddress]::TryParse($PveIP, [ref]$parsedPve) -or $parsedPve.AddressFamily -ne 'InterNetwork' -or $parsedPve.ToString() -ne $PveIP) { throw 'PveIP must be a single, canonical IPv4 address.' }
    $parsedClient = $null
    if (-not [Net.IPAddress]::TryParse($ClientIP, [ref]$parsedClient) -or $parsedClient.AddressFamily -ne 'InterNetwork' -or $parsedClient.ToString() -ne $ClientIP) { throw 'Provide the authorized SSH client Tailscale IPv4 with -ClientIP.' }
    $clientBytes = $parsedClient.GetAddressBytes()
    if ($clientBytes[0] -ne 100 -or $clientBytes[1] -lt 64 -or $clientBytes[1] -gt 127) { throw 'ClientIP must be in the Tailscale 100.64.0.0/10 range.' }
    if ($SshUser -notmatch '^[a-zA-Z0-9_.-]+$') { throw 'SshUser must be a local Windows account name.' }
}
if (-not $Apply) {
    [pscustomobject]@{
        Mode='PREVIEW ONLY';AllowTcpForwarding='local'
        PermitOpen=('localhost:* 127.0.0.1:* [::1]:* ' + $PveIP + ':8006')
        RemoteForwarding='disabled';GatewayPorts='no';RestoreFrom=$RestoreFrom
        ApplyCommand='Run this script with -Apply from an administrator PowerShell or an administrator SSH session.'
    } | ConvertTo-Json
    return
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw 'An administrator PowerShell/SSH session is required to update and restart the system SSH service.'
}
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw 'Install the SSH server first.' }
if (-not (Test-Path -LiteralPath $configPath)) { throw 'The existing SSH configuration is missing.' }
$sshd = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
$tailscale = Get-Command tailscale.exe -ErrorAction SilentlyContinue
$tailscalePath = if ($tailscale) { $tailscale.Source } else { Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }
if (-not (Test-Path -LiteralPath $tailscalePath)) { throw 'Tailscale must be installed and connected.' }
$tailStatus = & $tailscalePath status --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $tailStatus.BackendState -ne 'Running') { throw 'Connect Windows to Tailscale first.' }
$windowsIP = @($tailStatus.Self.TailscaleIPs | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)[0]
if (-not $windowsIP) { throw 'Windows has no Tailscale IPv4 address.' }
$original = [IO.File]::ReadAllBytes($configPath)
$originalAcl = (Get-Acl -LiteralPath $configPath).Sddl
if ($RestoreFrom) {
    $restorePath = (Resolve-Path -LiteralPath $RestoreFrom).Path
    if (-not $restorePath.StartsWith($backupRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'RestoreFrom must be a forwarding backup created by this helper.' }
    $desired = [IO.File]::ReadAllBytes((Join-Path $restorePath 'sshd_config'))
} else {
    $desiredText = Get-ForwardingConfig ([IO.File]::ReadAllText($configPath)) $PveIP
    $desired = [Text.UTF8Encoding]::new($false).GetBytes($desiredText)
}
$backup = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Protect-Backup $backup
[IO.File]::WriteAllBytes((Join-Path $backup 'sshd_config'),$original)
$candidate = Join-Path $backup 'sshd_config.next'
[IO.File]::WriteAllBytes($candidate,$desired)
& $sshd -t -f $candidate
if ($LASTEXITCODE -ne 0) { throw 'The proposed SSH configuration is invalid; the running configuration was not changed.' }
$effective = Get-EffectiveForwarding $sshd $candidate $SshUser $ClientIP
if (-not $RestoreFrom) {
    if ($effective['allowtcpforwarding'] -ne 'local' -or $effective['disableforwarding'] -ne 'no' -or $effective['permitlisten'] -ne 'none' -or $effective['gatewayports'] -ne 'no') { throw 'The proposed configuration does not enforce the expected forwarding policy.' }
    if ($effective['permitopen'] -ne ('localhost:* 127.0.0.1:* [::1]:* '+$PveIP+':8006')) { throw 'The proposed forwarding destinations do not match the expected policy.' }
}
$changed = $false
try {
    [IO.File]::WriteAllBytes($configPath,$desired)
    $changed = $true
    if ((Get-Acl -LiteralPath $configPath).Sddl -ne $originalAcl) { throw 'SSH configuration permissions changed unexpectedly.' }
    Restart-Service sshd -ErrorAction Stop
    $ready = $false
    for ($attempt=0; $attempt -lt 40; $attempt++) {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue)
        if ($listeners.LocalAddress -contains $windowsIP) { $ready=$true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $ready -or @($listeners | Where-Object LocalAddress -ne $windowsIP).Count) { throw 'SSH did not return with its original Tailscale-only listener.' }
    $result = [ordered]@{
        success=$true;verifiedAt=[DateTime]::UtcNow.ToString('o')
        mode=$(if($RestoreFrom){'restored'}else{'enabled'})
        allowTcpForwarding=$effective['allowtcpforwarding'];permitOpen=$effective['permitopen']
        permitListen=$effective['permitlisten'];gatewayPorts=$effective['gatewayports']
        pveIP=$PveIP;pvePort=8006;backupDirectory=$backup
        sshState=[string](Get-Service sshd).Status;listener=($windowsIP+':22')
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $resultPath) -Force | Out-Null
    [IO.File]::WriteAllText($resultPath,($result | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    $result | ConvertTo-Json -Depth 4
    Write-Output ('Undo: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Apply -RestoreFrom "'+$backup+'"')
    Write-Output 'Reconnect VS Code Remote-SSH to use the new policy.'
} catch {
    $failure = $_
    if ($changed) {
        [IO.File]::WriteAllBytes($configPath,$original)
        try { Restart-Service sshd -ErrorAction Stop } catch { Write-Warning ('Could not restart the restored SSH service: '+$_.Exception.Message) }
    }
    Write-Warning ('Previous configuration retained/restored. Backup: '+$backup)
    throw $failure
}
