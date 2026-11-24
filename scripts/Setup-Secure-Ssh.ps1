[CmdletBinding()]
param(
    [string]$WindowsIP,
    [string]$ArchIP,
    [string]$PublicKeyPath,
    [string]$TargetUser,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
function Assert-TailscaleIP([string]$Value) {
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or $parsed.AddressFamily -ne 'InterNetwork') { throw 'A single Tailscale IPv4 address is required.' }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes[0] -ne 100 -or $bytes[1] -lt 64 -or $bytes[1] -gt 127) { throw 'Use the Tailscale 100.64.0.0/10 addresses, not LAN or public IPs.' }
    return $parsed
}
function Set-PrivateAcl([string]$Path, [Security.Principal.SecurityIdentifier]$Owner, [switch]$Directory) {
    $allowed=@($Owner.Value,'S-1-5-18','S-1-5-32-544' | Select-Object -Unique)
    & icacls.exe $Path /setowner ('*' + $Owner.Value) | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Could not set the secure file owner.'}
    $grants=@($allowed | ForEach-Object { '*' + $_ + $(if($Directory){':(OI)(CI)F'}else{':F'}) })
    & icacls.exe $Path /inheritance:r /grant:r @grants | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Could not set the secure file permissions.'}
    foreach($rule in @((Get-Acl -LiteralPath $Path).Access)) {
        $sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if($sid -notin $allowed){& icacls.exe $Path /remove ('*' + $sid) | Out-Null; if($LASTEXITCODE -ne 0){throw 'Could not remove an unexpected file permission.'}}
    }
}
function Assert-HostKeyAcl([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $allowed = @('S-1-5-18','S-1-5-32-544')
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {
        throw ('SSH host private key must be owned by SYSTEM or Administrators: ' + $Path)
    }
    foreach ($rule in @($acl.Access)) {
        if ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed -or $rule.AccessControlType -ne 'Allow') {
            throw ('Unexpected access rule on SSH host private key: ' + $Path)
        }
    }
    foreach ($sid in $allowed) {
        $fullControl = @($acl.Access | Where-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $sid -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
        })
        if (-not $fullControl.Count) { throw ('Missing SYSTEM/Administrators access to SSH host private key: ' + $Path) }
    }
}
function Save-SshStartDiagnostics([string]$BackupDirectory, [string]$ConfigDirectory) {
    $lines = @('Checked at: ' + [DateTime]::UtcNow.ToString('o'))
    try { $lines += Get-CimInstance Win32_Service -Filter "Name='sshd'" | Select-Object Name,State,StartMode,ExitCode,ServiceSpecificExitCode,PathName | Format-List | Out-String } catch { $lines += $_.Exception.Message }
    foreach ($file in @((Join-Path $ConfigDirectory 'sshd_config'),(Join-Path $ConfigDirectory 'ssh_host_ed25519_key'),(Join-Path $ConfigDirectory 'logs'))) {
        try { if (Test-Path -LiteralPath $file) { $acl=Get-Acl -LiteralPath $file; $lines += ($file + ': ' + $acl.Sddl) } } catch { $lines += $_.Exception.Message }
    }
    foreach ($logName in @('OpenSSH/Operational','OpenSSH/Admin')) {
        try { $lines += Get-WinEvent -LogName $logName -MaxEvents 8 -ErrorAction Stop | Select-Object TimeCreated,Id,Message | Format-List | Out-String } catch { $lines += ($logName + ': ' + $_.Exception.Message) }
    }
    $logPath = Join-Path $ConfigDirectory 'logs\sshd.log'
    if (Test-Path -LiteralPath $logPath) { try { $lines += Get-Content -LiteralPath $logPath -Tail 35 } catch { $lines += $_.Exception.Message } }
    $reportPath = Join-Path $BackupDirectory 'start-diagnostics.txt'
    [IO.File]::WriteAllText($reportPath,($lines -join "`r`n"),[Text.UTF8Encoding]::new($false))
    Write-Warning ('SSH diagnostics saved before rollback: ' + $reportPath)
    foreach ($line in $lines) { Write-Host $line }
}
if (-not $TargetUser) { $TargetUser = $env:USERNAME.ToLowerInvariant() }
if ($WindowsIP) { [void](Assert-TailscaleIP $WindowsIP) }
if ($ArchIP) { [void](Assert-TailscaleIP $ArchIP) }
if ($TargetUser -cnotmatch '^[a-z0-9_.-]+$') { throw 'TargetUser must be a lowercase local Windows account name.' }
$account = Get-LocalUser -Name $TargetUser -ErrorAction Stop
$adminMembers = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
$isAdministratorAccount = @($adminMembers | Where-Object { $_.SID.Value -eq $account.SID.Value }).Count -gt 0
$plan = [ordered]@{
    mode = $(if($Apply){'APPLY'}else{'PREVIEW ONLY'})
    account = $TargetUser
    accountPrivileges = $(if($isAdministratorAccount){'Administrator account; SSH uses this existing account and its file access'}else{'Standard local account'})
    listenAddress = $(if($WindowsIP){$WindowsIP}else{'<Windows Tailscale IPv4>'})
    onlyAllowedClient = $(if($ArchIP){$ArchIP}else{'<Arch Tailscale IPv4>'})
    port = 22
    authentication = 'Ed25519 public key only; password and keyboard-interactive disabled'
    forwarding = 'Local loopback TCP forwarding for VS Code; remote TCP and agent forwarding disabled'
    keyFile = $(if($isAdministratorAccount){'ProgramData/ssh/authorized_keys_codex_' + $TargetUser + ' (Administrators and SYSTEM only)'}else{'User profile/.ssh/authorized_keys_codex_private (separate file)'})
    firewall = 'Allow the specified Arch IP; explicitly block all other IPv4 clients on this SSH listener'
    startup = 'Delayed automatic, depends on Tailscale service, with service recovery'
    backup = 'C:/ProgramData/CodexPrivateSSH/backups/<timestamp>'
}
$plan | ConvertTo-Json -Depth 4
if (-not $Apply) { Write-Output 'No changes made. Supply both device IPs and the Arch .pub file, then add -Apply in an administrator PowerShell.'; return }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator PowerShell is required to install sshd and configure Windows Firewall.' }
if (-not $WindowsIP -or -not $ArchIP -or -not $PublicKeyPath) { throw '-WindowsIP, -ArchIP and -PublicKeyPath are required with -Apply.' }
if ($WindowsIP -eq $ArchIP) { throw 'Windows and Arch addresses must differ.' }
if (-not (Get-Service Tailscale -ErrorAction SilentlyContinue)) { throw 'Install and connect Tailscale first.' }
$binding = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $WindowsIP -ErrorAction Stop | Select-Object -First 1
if ($binding.InterfaceAlias -notmatch 'Tailscale') { throw 'WindowsIP is not assigned to a Tailscale interface.' }
$profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
if (@($profiles | Where-Object { -not $_.Enabled -or $_.DefaultInboundAction -eq 'Allow' }).Count) { throw 'Windows Firewall must be enabled with incoming connections blocked by default before applying this configuration.' }
if (-not $account.Enabled) { throw 'The target Windows account is disabled.' }
$profile = (Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $account.SID.Value)).ProfileImagePath
$profile = [Environment]::ExpandEnvironmentVariables($profile)
if (-not (Test-Path -LiteralPath $profile -PathType Container)) { throw 'The target account must have an existing Windows profile.' }
$keys = @(Get-Content -LiteralPath $PublicKeyPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
if (-not $keys.Count) { throw 'The provided .pub file is empty.' }
foreach ($key in $keys) {
    if ($key -notmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}(?: [^\r\n]*)?$') { throw 'Provide only ssh-ed25519 public keys. Never provide a private key.' }
    $encoded = ($key -split ' ')[1]
    $decoded = [Convert]::FromBase64String($encoded)
    if ($decoded.Length -ne 51 -or [Text.Encoding]::ASCII.GetString($decoded,4,11) -ne 'ssh-ed25519') { throw 'Invalid Ed25519 public key encoding.' }
}
$sshDir = Join-Path $profile '.ssh'
$configDir = Join-Path $env:ProgramData 'ssh'
$authorized = if($isAdministratorAccount){Join-Path $configDir ('authorized_keys_codex_' + $TargetUser)}else{Join-Path $sshDir 'authorized_keys_codex_private'}
$configPath = Join-Path $configDir 'sshd_config'
$logDir = Join-Path $configDir 'logs'
$oldService = Get-Service sshd -ErrorAction SilentlyContinue
$serviceReg = 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd'
$priorDepends = if (Test-Path -LiteralPath $serviceReg) { @((Get-ItemProperty -LiteralPath $serviceReg -Name DependOnService -ErrorAction SilentlyContinue).DependOnService) } else { @() }
$priorServiceProperties = if(Test-Path -LiteralPath $serviceReg){Get-ItemProperty -LiteralPath $serviceReg}else{$null}
$defaultRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
$managedRules = @(Get-NetFirewallRule -Name 'CodexPrivateSSH-*' -ErrorAction SilentlyContinue)
if ($managedRules.Count) { throw 'A managed SSH configuration already exists. Use Restore-Secure-Ssh.ps1 with its backup before applying a new setup.' }
$backup = Join-Path (Join-Path $env:ProgramData 'CodexPrivateSSH\backups') ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Set-PrivateAcl $backup ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')) -Directory
$snapshot = [ordered]@{
    configPath=$configPath; configExisted=(Test-Path -LiteralPath $configPath)
    authorizedPath=$authorized; authorizedExisted=(Test-Path -LiteralPath $authorized)
    sshDir=$sshDir; sshDirExisted=(Test-Path -LiteralPath $sshDir)
    sshDirManaged=(-not $isAdministratorAccount)
    sshDirSddl=$(if(Test-Path -LiteralPath $sshDir){(Get-Acl -LiteralPath $sshDir).Sddl}else{''})
    serviceExisted=[bool]$oldService; serviceWasRunning=($oldService -and $oldService.Status -eq 'Running')
    serviceStartType=$(if($oldService){[string]$oldService.StartType}else{'Disabled'})
    serviceExtraProperties=@{}
    priorDepends=@($priorDepends | Where-Object { $_ })
    defaultRuleExisted=[bool]$defaultRule; defaultRuleEnabled=$(if($defaultRule){[string]$defaultRule.Enabled}else{''})
    hostKeyAcls=@(if(Test-Path -LiteralPath $configDir){Get-ChildItem -LiteralPath $configDir -Filter 'ssh_host_*_key' -File | ForEach-Object { [ordered]@{path=$_.FullName;sddl=(Get-Acl -LiteralPath $_.FullName).Sddl} }})
    logDir=$logDir; logDirExisted=(Test-Path -LiteralPath $logDir)
    logDirSddl=$(if(Test-Path -LiteralPath $logDir){(Get-Acl -LiteralPath $logDir).Sddl}else{''})
}
foreach($name in @('DelayedAutoStart','FailureActions','FailureActionsOnNonCrashFailures')) {
    $property = if($priorServiceProperties){$priorServiceProperties.PSObject.Properties[$name]}else{$null}
    if($property){$snapshot.serviceExtraProperties[$name]=@{kind=$(if($property.Value -is [byte[]]){'Binary'}else{'DWord'});value=$(if($property.Value -is [byte[]]){[Convert]::ToBase64String($property.Value)}else{$property.Value})}}
}
if ($snapshot.configExisted) { Copy-Item -LiteralPath $configPath -Destination (Join-Path $backup 'sshd_config'); $snapshot.configSddl=(Get-Acl -LiteralPath $configPath).Sddl }
if ($snapshot.authorizedExisted) { Copy-Item -LiteralPath $authorized -Destination (Join-Path $backup 'authorized_keys'); $snapshot.authorizedSddl=(Get-Acl -LiteralPath $authorized).Sddl }
[IO.File]::WriteAllText((Join-Path $backup 'snapshot.json'),($snapshot | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Output ('Backup: ' + $backup)
try {
    if (-not $oldService) {
        $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
        if ($capability.State -ne 'Installed') { $install=Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'; if($install.RestartNeeded){throw 'Windows requires a restart after installing OpenSSH. Restart, then rerun this script.'} }
    }
    $sshd = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    $keygen = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe'
    if (-not (Test-Path -LiteralPath $sshd)) { throw 'Windows OpenSSH Server was not installed successfully.' }
    Stop-Service sshd -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    if(-not $isAdministratorAccount){
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        Set-PrivateAcl $sshDir $account.SID -Directory
    }
    [IO.File]::WriteAllText($authorized,($keys -join "`n") + "`n",[Text.UTF8Encoding]::new($false))
    $keyOwner = if($isAdministratorAccount){[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')}else{$account.SID}
    Set-PrivateAcl $authorized $keyOwner
    & $keygen -lf $authorized
    if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen rejected the public key.' }
    & $keygen -A
    if ($LASTEXITCODE -ne 0) { throw 'SSH host key creation failed.' }
    # ssh-keygen -A can leave keys owned by the interactive administrator.
    # The SYSTEM service requires SYSTEM/Administrators ownership and access only.
    foreach ($hostKey in Get-ChildItem -LiteralPath $configDir -Filter 'ssh_host_*_key' -File) {
        Set-PrivateAcl $hostKey.FullName ([Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
        Assert-HostKeyAcl $hostKey.FullName
    }
    Write-Output 'SSH host private key ownership and ACL checks passed (SYSTEM and Administrators only).'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Set-PrivateAcl $logDir ([Security.Principal.SecurityIdentifier]::new('S-1-5-18')) -Directory
    $keyPathForConfig = $authorized.Replace('\','/')
    $config = @"
# Managed by Codex Remote Access. Restore using the recorded backup directory.
Port 22
AddressFamily inet
ListenAddress $WindowsIP
HostKey __PROGRAMDATA__/ssh/ssh_host_ed25519_key
HostKeyAlgorithms ssh-ed25519
PubkeyAuthentication yes
PubkeyAcceptedAlgorithms ssh-ed25519
AuthorizedKeysFile "$keyPathForConfig"
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowUsers $TargetUser
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 30
ClientAliveInterval 60
ClientAliveCountMax 3
AllowAgentForwarding no
AllowTcpForwarding local
PermitOpen localhost:* 127.0.0.1:* [::1]:*
PermitListen none
GatewayPorts no
X11Forwarding no
SyslogFacility LOCAL0
LogLevel VERBOSE
Subsystem sftp sftp-server.exe
"@
    [IO.File]::WriteAllText($configPath,$config + "`n",[Text.UTF8Encoding]::new($false))
    Set-PrivateAcl $configPath ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    & $sshd -t -f $configPath
    if ($LASTEXITCODE -ne 0) { throw 'sshd configuration syntax validation failed.' }
    $bytes = (Assert-TailscaleIP $ArchIP).GetAddressBytes()
    [Array]::Reverse($bytes)
    $number = [BitConverter]::ToUInt32($bytes,0)
    function Convert-IPv4Number([uint32]$Value) { $b=[BitConverter]::GetBytes($Value); [Array]::Reverse($b); return ([Net.IPAddress]::new($b)).ToString() }
    $blocked = @(
        ('0.0.0.0-' + (Convert-IPv4Number ($number-1)))
        ((Convert-IPv4Number ($number+1)) + '-255.255.255.255')
    )
    New-NetFirewallRule -Name 'CodexPrivateSSH-Allow' -DisplayName 'Codex SSH: Arch via Tailscale only' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -LocalAddress $WindowsIP -RemoteAddress $ArchIP -InterfaceAlias $binding.InterfaceAlias -Profile Any | Out-Null
    New-NetFirewallRule -Name 'CodexPrivateSSH-BlockOthers' -DisplayName 'Codex SSH: block other client addresses' -Direction Inbound -Action Block -Protocol TCP -LocalPort 22 -LocalAddress $WindowsIP -RemoteAddress $blocked -Profile Any | Out-Null
    Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
    $depends = @(@($priorDepends) + @('Tailscale') | Where-Object { $_ } | Select-Object -Unique)
    New-ItemProperty -LiteralPath $serviceReg -Name DependOnService -PropertyType MultiString -Value $depends -Force | Out-Null
    & sc.exe config sshd start= delayed-auto | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure delayed SSH service startup.' }
    & sc.exe failure sshd reset= 86400 actions= restart/30000/restart/60000/restart/60000 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure SSH service recovery.' }
    try {
        Start-Service sshd -ErrorAction Stop
        $listenerReady = $false
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            $listener = @(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue)
            if ($listener.LocalAddress -contains $WindowsIP) { $listenerReady = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $listenerReady -or @($listener | Where-Object LocalAddress -ne $WindowsIP).Count) { throw 'SSH did not open the expected Tailscale-only listener. Inspect the saved startup diagnostics.' }
    }
    catch {
        try { Save-SshStartDiagnostics $backup $configDir } catch { Write-Warning ('Could not save SSH startup diagnostics: ' + $_.Exception.Message) }
        throw
    }
    Write-Output 'SSH configured. Verify this host fingerprint in person before accepting the first Arch connection:'
    & $keygen -lf (Join-Path $configDir 'ssh_host_ed25519_key.pub')
    Write-Output ('Connect from Arch: ssh -i ~/.ssh/codex-windows ' + $TargetUser + '@' + $WindowsIP)
    Write-Output ('Rollback: & "' + (Join-Path $PSScriptRoot 'Restore-Secure-Ssh.ps1') + '" -BackupDirectory "' + $backup + '"')
} catch {
    $failure = $_
    Write-Warning 'Setup failed. Restoring the recorded configuration.'
    & (Join-Path $PSScriptRoot 'Restore-Secure-Ssh.ps1') -BackupDirectory $backup
    throw $failure
}
