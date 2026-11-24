[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PlanPath,
    [string]$PlanSha256,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Access-Common.psm1') -Force -DisableNameChecking
$root = Split-Path -Parent $PSScriptRoot
if ($Apply -and -not $PlanSha256) { throw '-Apply requires the reviewed -PlanSha256. Use Setup.ps1 to generate and review the plan.' }
$planPathFull = [IO.Path]::GetFullPath($PlanPath)
$planDirectory = [IO.Path]::GetFullPath((Join-Path $root 'state\onboarding')) + '\'
if (-not $planPathFull.StartsWith($planDirectory, [StringComparison]::OrdinalIgnoreCase)) { throw 'The plan must be inside this bundle state/onboarding directory.' }
if ($PlanSha256 -and (Get-FileHash -LiteralPath $planPathFull).Hash -ine $PlanSha256) { throw 'The plan changed after it was reviewed. Run Setup.ps1 again.' }
$plan = Get-Content -LiteralPath $planPathFull -Raw | ConvertFrom-Json
if ($plan.version -ne 1) { throw 'Unsupported access plan.' }
Assert-AccessProfile $plan.Previous
Assert-AccessProfile $plan.Desired
if (($plan.Previous.host | ConvertTo-Json -Compress) -ne ($plan.Desired.host | ConvertTo-Json -Compress)) { throw 'Host changes are not supported by a device access update.' }
$sshIPs = @($plan.Desired.devices | Where-Object Ssh | ForEach-Object IP)
$rustIPs = @($plan.Desired.devices | Where-Object RustDesk | ForEach-Object IP)
if (-not $Apply) {
    [pscustomobject]@{PreviewOnly=$true;SshClients=$sshIPs;SshBlockRanges=@(Get-BlockedIPv4Ranges $sshIPs);RustDeskClients=$rustIPs;Authentication='Per-device Ed25519 keys / RustDesk permanent password';RequiresAdministrator='SSH authorized keys, Windows Firewall and RustDesk system service';RestartsExistingSsh=$false} | ConvertTo-Json -Depth 8
    return
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this helper as Administrator: it changes protected SSH keys, firewall rules and RustDesk service settings.' }
$tailnet = Get-AccessTailnet
if ($tailnet.NodeId -ne $plan.Desired.host.NodeId -or $tailnet.IP -ne $plan.Desired.host.IP -or $tailnet.DNS -ne $plan.Desired.host.DNS) { throw 'The Tailscale host changed after this plan was generated.' }
Assert-PrivateServe $tailnet
foreach ($device in @($plan.Desired.devices | Where-Object { -not $_.LegacySsh })) {
    if ($device.NodeId -and -not @($tailnet.Peers | Where-Object { $_.ID -eq $device.NodeId -and $_.TailscaleIPs -contains $device.IP }).Count) { throw ('Device no longer matches Tailscale: ' + $device.Name) }
}
$profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
if (@($profiles | Where-Object { -not $_.Enabled -or $_.DefaultInboundAction -eq 'Allow' }).Count) { throw 'Windows Firewall must be enabled and block unsolicited incoming traffic.' }
$receiptPath = $planPathFull + '.result.json'
$receipt = [ordered]@{version=1;PlanSha256=(Get-FileHash -LiteralPath $planPathFull).Hash;SshApplied=$false;BootstrapDeviceId='';RustDeskApplied=$false;Success=$false;Error='';BackupDirectory='';CompletedAt=''}

function Protect-AccessBackup([string]$Path) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Assert-SshConfigValid([string]$ConfigPath) {
    & (Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe') -t -f $ConfigPath
    if ($LASTEXITCODE -ne 0) { throw 'SSH configuration validation failed.' }
}
function Assert-ProtectedKeyPath([string]$Path,[string]$UserSid,[bool]$AdministratorFile) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'A protected SSH path contains a junction or symbolic link. Review it before writing.' }
        $cursor = Split-Path -Parent $cursor
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $allowed = @('S-1-5-18','S-1-5-32-544')
    if (-not $AdministratorFile) { $allowed += $UserSid }
    $acl = Get-Acl -LiteralPath $Path
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) { throw 'Unexpected owner on the SSH authorized key file.' }
    foreach ($rule in @($acl.Access)) {
        if ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed -or $rule.AccessControlType -ne 'Allow') { throw 'SSH authorized key permissions are broader than the managed setup. Review them first.' }
    }
}
function Update-SshDeviceAccess {
    $bootstrapped = $false
    $oldAllow = Get-NetFirewallRule -Name 'CodexPrivateSSH-Allow' -ErrorAction SilentlyContinue
    $oldBlock = Get-NetFirewallRule -Name 'CodexPrivateSSH-BlockOthers' -ErrorAction SilentlyContinue
    if (-not $oldAllow -and -not $sshIPs.Count) { return }
    if (-not $oldAllow) {
        if (Get-Service sshd -ErrorAction SilentlyContinue) { throw 'An unmanaged SSH server exists. This wizard will not replace it. Review it with an administrator first.' }
        $first = @($plan.Desired.devices | Where-Object Ssh)[0]
        if ($first.LegacySsh) { throw 'Cannot bootstrap SSH without a new device public key.' }
        $publicFile = $planPathFull + '.pub'
        [IO.File]::WriteAllText($publicFile, (ConvertTo-PublicKey $first.PublicKey) + "`n", [Text.UTF8Encoding]::new($false))
        try { & (Join-Path $PSScriptRoot 'Setup-Secure-Ssh.ps1') -WindowsIP $tailnet.IP -ArchIP $first.IP -PublicKeyPath $publicFile -TargetUser $plan.Desired.host.User -Apply }
        finally { Remove-Item -LiteralPath $publicFile -Force -ErrorAction SilentlyContinue }
        $oldAllow = Get-NetFirewallRule -Name 'CodexPrivateSSH-Allow'
        $oldBlock = Get-NetFirewallRule -Name 'CodexPrivateSSH-BlockOthers'
        $bootstrapped = $true
        # If a later update fails, the initial installer has still authorized this ONE key.
        # Record it so the wizard can import this baseline on retry instead of losing track of it.
        $receipt.BootstrapDeviceId = $first.Id
        Write-AccessJson $receiptPath $receipt
        Write-Host 'Initial SSH server installed. Its original setup backup is retained under ProgramData/CodexPrivateSSH/backups.'
    }
    if (-not $oldBlock) { throw 'Managed SSH block rule is missing. Review firewall before changing access.' }
    foreach ($rule in @($oldAllow,$oldBlock)) {
        $localAddresses = @($rule | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty LocalAddress)
        if ($localAddresses.Count -ne 1 -or $localAddresses[0] -ne $tailnet.IP) { throw 'Managed SSH rule is no longer scoped to this host Tailscale IP. Review it before adding a device.' }
    }
    if (-not $bootstrapped) {
        $expectedIPs = @($plan.Previous.devices | Where-Object Ssh | ForEach-Object IP | Sort-Object) -join ','
        $actualIPs = if ([string]$oldAllow.Enabled -eq 'True') { @($oldAllow | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress | Sort-Object) -join ',' } else { '' }
        if ($expectedIPs -ne $actualIPs) { throw 'The SSH allow-list changed outside the wizard. Review and reconcile it before applying this plan.' }
    }
    $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
    $configText = Get-Content -LiteralPath $configPath -Raw
    if ($configText -notmatch '(?m)^# Managed by Codex Remote Access\.' -or $configText -match '(?im)^\s*(Match|Include)\s') { throw 'SSH configuration is unmanaged or uses Match/Include; refusing to replace it.' }
    $userMatch = [regex]::Match($configText,'(?im)^\s*AllowUsers\s+([^\r\n]+)')
    if (-not $userMatch.Success -or $userMatch.Groups[1].Value.Trim() -cne $plan.Desired.host.User) { throw 'The SSH account does not match this device profile.' }
    $keyMatch = [regex]::Match($configText,'(?im)^\s*AuthorizedKeysFile\s+"([^"\r\n]+)"\s*$')
    if (-not $keyMatch.Success) { throw 'Expected one explicitly quoted managed AuthorizedKeysFile.' }
    $keyPath = [IO.Path]::GetFullPath($keyMatch.Groups[1].Value)
    $account = Get-LocalUser -Name $plan.Desired.host.User
    $profileDir = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $account.SID.Value)).ProfileImagePath)
    $expected = @((Join-Path $env:ProgramData ('ssh\authorized_keys_codex_' + $plan.Desired.host.User)), (Join-Path $profileDir '.ssh\authorized_keys_codex_private'))
    if ($keyPath -notin $expected) { throw 'Unexpected authorized key file; refusing to write it.' }
    Assert-ProtectedKeyPath $keyPath $account.SID.Value ($keyPath -eq $expected[0])
    $ledgerRoot = Join-Path $env:ProgramData 'CodexPrivateSSH\devices'
    Assert-ProtectedKeyPath $ledgerRoot $account.SID.Value $true
    [void](New-Item -ItemType Directory -Path $ledgerRoot -Force)
    Protect-AccessBackup $ledgerRoot
    $ledgerPath = Join-Path $ledgerRoot 'legacy-keys.json'
    $legacyLines = @()
    if (Test-Path -LiteralPath $ledgerPath) {
        $legacyLines = @((Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json).Lines | ForEach-Object { ConvertTo-PublicKey ([string]$_) })
    } elseif (@($plan.Previous.devices | Where-Object { $_.Ssh -and $_.LegacySsh }).Count) {
        # Convert each line to a new plain string. Windows PowerShell 5.1 Get-Content
        # attaches provider metadata which ConvertTo-Json otherwise traverses recursively.
        $legacyLines = @(Get-Content -LiteralPath $keyPath | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { ConvertTo-PublicKey ([string]$_) })
    }
    $newText = Get-AuthorizedKeyText $legacyLines $plan.Desired
    if (Test-Path -LiteralPath $ledgerPath) {
        $expectedText = Get-AuthorizedKeyText $legacyLines $plan.Previous
        $actualText = (Get-Content -LiteralPath $keyPath -Raw).Replace("`r`n","`n")
        if ($expectedText -cne $actualText) { throw 'The authorized key file changed outside the wizard. It was preserved; review it before applying this plan.' }
    } elseif (-not $bootstrapped -and -not @($plan.Previous.devices | Where-Object { $_.Ssh -and $_.LegacySsh }).Count) {
        throw 'The protected legacy-key record is missing. Refusing to overwrite an unrecognized key file.'
    }
    $backup = Join-Path $ledgerRoot ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    [void](New-Item -ItemType Directory -Path $backup)
    $receipt.BackupDirectory = $backup
    $oldText = Get-Content -LiteralPath $keyPath -Raw
    $oldAllowAddresses = @($oldAllow | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress)
    $oldBlockAddresses = @($oldBlock | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress)
    $snapshot = [ordered]@{KeyPath=$keyPath;AllowAddresses=$oldAllowAddresses;AllowEnabled=[string]$oldAllow.Enabled;BlockAddresses=$oldBlockAddresses;BlockEnabled=[string]$oldBlock.Enabled;OriginalKeySddl=(Get-Acl -LiteralPath $keyPath).Sddl}
    Write-AccessJson (Join-Path $backup 'snapshot.json') $snapshot
    [IO.File]::WriteAllText((Join-Path $backup 'authorized_keys'),$oldText,[Text.UTF8Encoding]::new($false))
    $ledgerExisted = Test-Path -LiteralPath $ledgerPath
    try {
        # First close the listener to new connections during replacement; existing SSH sessions survive.
        Set-NetFirewallRule -Name $oldBlock.Name -RemoteAddress Any -Enabled True | Out-Null
        [IO.File]::WriteAllText($keyPath,$newText,[Text.UTF8Encoding]::new($false))
        Assert-SshConfigValid $configPath
        if ($sshIPs.Count) { Set-NetFirewallRule -Name $oldAllow.Name -RemoteAddress $sshIPs -Enabled True | Out-Null }
        else { Set-NetFirewallRule -Name $oldAllow.Name -Enabled False | Out-Null }
        Set-NetFirewallRule -Name $oldBlock.Name -RemoteAddress @(Get-BlockedIPv4Ranges $sshIPs) -Enabled True | Out-Null
        if (-not $ledgerExisted) { Write-AccessJson $ledgerPath ([ordered]@{Lines=@($legacyLines)}) }
        Write-Host 'SSH device keys and allow/block rules updated. Existing sshd configuration, shell, forwarding and sessions were preserved.'
    } catch {
        $failure = $_
        # Stay closed until key and allow-list restoration have succeeded.
        Set-NetFirewallRule -Name $oldBlock.Name -RemoteAddress Any -Enabled True | Out-Null
        [IO.File]::WriteAllText($keyPath,$oldText,[Text.UTF8Encoding]::new($false))
        Set-NetFirewallRule -Name $oldAllow.Name -RemoteAddress $oldAllowAddresses -Enabled $snapshot.AllowEnabled | Out-Null
        Set-NetFirewallRule -Name $oldBlock.Name -RemoteAddress $oldBlockAddresses -Enabled $snapshot.BlockEnabled | Out-Null
        throw $failure
    }
}

try {
    Update-SshDeviceAccess
    $receipt.SshApplied = $true
    if (Get-Service sshd -ErrorAction SilentlyContinue) {
        $hostKey = Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key.pub'
        if (Test-Path -LiteralPath $hostKey) {
            $keyFingerprint = & (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe') -lf $hostKey
            if ($LASTEXITCODE -ne 0 -or $keyFingerprint -notmatch '(SHA256:[a-zA-Z0-9+/]{43})') { throw 'Could not export the SSH host public fingerprint.' }
            [IO.File]::WriteAllText((Join-Path $root 'state\onboarding\ssh-host-fingerprint.txt'),$Matches[1] + "`n",[Text.UTF8Encoding]::new($false))
        }
    }
    Write-AccessJson $receiptPath $receipt
    # RustDesk has its own settings/service/firewall backup and rollback. It never receives a password.
    $rustChanged = (@($plan.Previous.devices | Where-Object RustDesk | ForEach-Object IP | Sort-Object) -join ',') -ne (@($rustIPs | Sort-Object) -join ',')
    if ($rustChanged) {
        if ($rustIPs.Count) {
            $rustParameters = @{AllowedClientIPs=$rustIPs;Apply=$true}
            if ($plan.RustDeskSourcePath) { $rustParameters.SourcePath = $plan.RustDeskSourcePath }
            & (Join-Path $PSScriptRoot 'Configure-RustDesk.ps1') @rustParameters
        }
        else { & (Join-Path $PSScriptRoot 'Configure-RustDesk.ps1') -DisableDirect -Apply }
    }
    $receipt.RustDeskApplied = $true
    if ($plan.ConfigureShell) { & (Join-Path $PSScriptRoot 'Configure-Ssh-PowerShell.ps1') -Apply }
    $receipt.Success = $true
} catch {
    $receipt.Error = $_.Exception.Message
    Write-Warning ('Setup incomplete: ' + $receipt.Error)
    Write-Warning 'The receipt records which steps succeeded. Setup.ps1 will preserve those results; retry the remaining step. It will not claim full success.'
} finally {
    $receipt.CompletedAt = [DateTime]::UtcNow.ToString('o')
    Write-AccessJson $receiptPath $receipt
}
if (-not $receipt.Success) { throw $receipt.Error }
Write-Host 'System access settings completed. Tailscale cloud policy and client-side login checks are separate steps in Setup.ps1.'
