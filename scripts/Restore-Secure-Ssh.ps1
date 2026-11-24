[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BackupDirectory)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator PowerShell is required for rollback.' }
$snapshot=Get-Content -LiteralPath (Join-Path $BackupDirectory 'snapshot.json') -Raw | ConvertFrom-Json
Stop-Service sshd -ErrorAction SilentlyContinue
Get-NetFirewallRule -Name 'CodexPrivateSSH-*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($snapshot.configExisted) { Copy-Item -LiteralPath (Join-Path $BackupDirectory 'sshd_config') -Destination $snapshot.configPath -Force; $acl=Get-Acl -LiteralPath $snapshot.configPath; $acl.SetSecurityDescriptorSddlForm($snapshot.configSddl); Set-Acl -LiteralPath $snapshot.configPath -AclObject $acl } elseif(Test-Path -LiteralPath $snapshot.configPath) { Remove-Item -LiteralPath $snapshot.configPath -Force }
if ($snapshot.authorizedExisted) {
    Copy-Item -LiteralPath (Join-Path $BackupDirectory 'authorized_keys') -Destination $snapshot.authorizedPath -Force
    $acl=Get-Acl -LiteralPath $snapshot.authorizedPath; $acl.SetSecurityDescriptorSddlForm($snapshot.authorizedSddl); Set-Acl -LiteralPath $snapshot.authorizedPath -AclObject $acl
} elseif(Test-Path -LiteralPath $snapshot.authorizedPath) { Remove-Item -LiteralPath $snapshot.authorizedPath -Force }
if ($snapshot.sshDirExisted -and ($null -eq $snapshot.PSObject.Properties['sshDirManaged'] -or $snapshot.sshDirManaged)) { $acl=Get-Acl -LiteralPath $snapshot.sshDir; $acl.SetSecurityDescriptorSddlForm($snapshot.sshDirSddl); Set-Acl -LiteralPath $snapshot.sshDir -AclObject $acl }
if ($snapshot.PSObject.Properties['hostKeyAcls']) {
    foreach ($saved in @($snapshot.hostKeyAcls)) {
        if (Test-Path -LiteralPath $saved.path) { $acl=Get-Acl -LiteralPath $saved.path; $acl.SetSecurityDescriptorSddlForm($saved.sddl); Set-Acl -LiteralPath $saved.path -AclObject $acl }
    }
}
if ($snapshot.PSObject.Properties['logDirExisted'] -and $snapshot.logDirExisted) { $acl=Get-Acl -LiteralPath $snapshot.logDir; $acl.SetSecurityDescriptorSddlForm($snapshot.logDirSddl); Set-Acl -LiteralPath $snapshot.logDir -AclObject $acl }
$service=Get-Service sshd -ErrorAction SilentlyContinue
if ($service) {
    if ($snapshot.priorDepends.Count) { New-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd' -Name DependOnService -PropertyType MultiString -Value @($snapshot.priorDepends) -Force | Out-Null } else { Remove-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd' -Name DependOnService -ErrorAction SilentlyContinue }
    Set-Service sshd -StartupType $snapshot.serviceStartType
    foreach($name in @('DelayedAutoStart','FailureActions','FailureActionsOnNonCrashFailures')) {
        $property=$snapshot.serviceExtraProperties.PSObject.Properties[$name]
        if($property){$saved=$property.Value; $value=if($saved.kind -eq 'Binary'){[Convert]::FromBase64String($saved.value)}else{[int]$saved.value}; New-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd' -Name $name -PropertyType $saved.kind -Value $value -Force | Out-Null}else{Remove-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\sshd' -Name $name -ErrorAction SilentlyContinue}
    }
    if ($snapshot.serviceWasRunning) { Start-Service sshd }
}
$defaultRule=Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($defaultRule) { if($snapshot.defaultRuleExisted){$defaultRule | Set-NetFirewallRule -Enabled $snapshot.defaultRuleEnabled}else{$defaultRule | Disable-NetFirewallRule} }
Write-Output 'Previous SSH configuration and managed firewall rules restored. An installed OpenSSH capability and generated host keys are retained; a newly installed SSH service is stopped and disabled.'
