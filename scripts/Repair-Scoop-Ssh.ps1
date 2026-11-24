[CmdletBinding()]
param([switch]$Apply, [string]$RestoreFrom)
$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
$backupRoot = Join-Path $bundleRoot 'state\scoop-ssh-backups'
$resultPath = Join-Path $bundleRoot 'state\scoop-ssh-result.json'
$registryPath = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sshd.exe'
$valueName = 'MitigationOptions'
$configPath = Join-Path $env:ProgramData 'ssh\sshd_config'

function Get-CompatibleMitigation([byte[]]$Bytes) {
    if ($Bytes.Length -lt 19) { throw 'This helper expects the RedirectionGuard setting at byte 18 of the OpenSSH mitigation value.' }
    $result = [byte[]]$Bytes.Clone()
    # OpenSSH PR #808 enables RedirectionGuard using precisely this bit.
    # Preserve every other mitigation bit, including the other bits in byte 18.
    $result[18] = [byte]($result[18] -band 0xef)
    return ,$result
}

function Read-MitigationRegistry($Key) {
    $exists = $null -ne $Key -and $Key.GetValueNames() -contains $valueName
    if ($exists -and $Key.GetValueKind($valueName) -ne [Microsoft.Win32.RegistryValueKind]::Binary) { throw 'The SSH mitigation value has an unexpected registry type.' }
    [byte[]]$bytes = @()
    if ($exists) { $bytes = [byte[]]$Key.GetValue($valueName) }
    return [pscustomobject]@{Exists=$exists;Bytes=$bytes;Base64=[Convert]::ToBase64String($bytes)}
}

function Write-MitigationRegistry($Key, $Snapshot) {
    if ($Snapshot.Exists) { $Key.SetValue($valueName, [byte[]]$Snapshot.Bytes, [Microsoft.Win32.RegistryValueKind]::Binary) }
    else { $Key.DeleteValue($valueName, $false) }
}

function Get-ListenerSnapshot {
    return @(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction Stop | ForEach-Object { $_.LocalAddress + ':' + $_.LocalPort } | Sort-Object -Unique)
}

function Test-SameListener([string[]]$Expected) {
    for ($attempt=0; $attempt -lt 60; $attempt++) {
        try { $actual = @(Get-ListenerSnapshot) } catch { $actual = @() }
        if (($actual -join '|') -eq ($Expected -join '|')) { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'SSH did not return with its original listener addresses.'
}

function Initialize-MitigationReader {
    if ('CodexScoopSsh.NativePolicy' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace CodexScoopSsh {
    public static class NativePolicy {
        [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetProcessMitigationPolicy(IntPtr process, int policy, out uint value, UIntPtr size);
        public static uint Read(int id) {
            IntPtr handle = OpenProcess(0x0400, false, id);
            if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                uint flags;
                if (!GetProcessMitigationPolicy(handle, 16, out flags, new UIntPtr(4))) throw new Win32Exception(Marshal.GetLastWin32Error());
                return flags;
            } finally { CloseHandle(handle); }
        }
    }
}
'@
}

function Get-ServiceRedirectionPolicy {
    Initialize-MitigationReader
    $service = Get-CimInstance Win32_Service -Filter "Name='sshd'"
    if (-not $service -or $service.State -ne 'Running' -or $service.ProcessId -eq 0) { throw 'The SSH service must be running.' }
    $flags = [CodexScoopSsh.NativePolicy]::Read([int]$service.ProcessId)
    return [pscustomobject]@{ProcessId=$service.ProcessId;Flags=$flags;EnforceRedirectionTrust=[bool]($flags -band 1);AuditRedirectionTrust=[bool]($flags -band 2)}
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if ($Apply -and -not $elevated) { throw 'Run from a Windows administrator PowerShell. Changing the SSH process mitigation and restarting sshd require administrator rights. No settings were changed.' }
$readKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($registryPath)
try { $original = Read-MitigationRegistry $readKey } finally { if ($readKey) { $readKey.Close() } }

if ($RestoreFrom) {
    $restorePath = (Resolve-Path -LiteralPath $RestoreFrom).Path
    $canonicalRoot = [IO.Path]::GetFullPath($backupRoot).TrimEnd('\') + '\'
    if (-not $restorePath.StartsWith($canonicalRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'RestoreFrom must be an original backup under state\scoop-ssh-backups.' }
    $record = Get-Content -LiteralPath (Join-Path $restorePath 'settings.json') -Raw | ConvertFrom-Json
    if ($record.Schema -ne 1 -or $record.RegistryPath -ne $registryPath -or $record.UserSid -ne $identity.User.Value) { throw 'The backup does not match this account or the SSH mitigation setting.' }
    $desiredBytes = [Convert]::FromBase64String([string]$record.OriginalBase64)
    $desired = [pscustomobject]@{Exists=[bool]$record.OriginalExists;Bytes=$desiredBytes;Base64=[string]$record.OriginalBase64}
} elseif ($original.Exists) {
    $desiredBytes = Get-CompatibleMitigation $original.Bytes
    $desired = [pscustomobject]@{Exists=$true;Bytes=$desiredBytes;Base64=[Convert]::ToBase64String($desiredBytes)}
} else {
    throw 'The expected OpenSSH mitigation value is absent. This helper will not guess another mitigation override.'
}

if (-not $Apply) {
    [pscustomobject]@{
        Mode='PREVIEW ONLY';RegistryPath=('HKLM:\'+$registryPath);RegistryValue=$valueName
        CurrentHex=[BitConverter]::ToString($original.Bytes);ProposedHex=[BitConverter]::ToString($desired.Bytes)
        ChangedBit='zero-based byte 18, mask 0x10 only';AppliesTo='sshd.exe only, including future SSH child processes'
        Effect='Allow SSH processes to traverse user-created Scoop current directory junctions'
        SecurityTradeoff='Removes RedirectionGuard enforcement from sshd; other process mitigations, authentication, firewall and forwarding settings are preserved'
        RestartRequired=$true;NewSshConnectionRequired=$true;Elevated=$elevated
    } | ConvertTo-Json -Depth 4
    return
}

$beforePolicy = Get-ServiceRedirectionPolicy
$beforeListener = @(Get-ListenerSnapshot)
$tailscale = Get-Command tailscale.exe -ErrorAction SilentlyContinue
$tailscalePath = if ($tailscale) { $tailscale.Source } else { Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe' }
if (-not (Test-Path -LiteralPath $tailscalePath)) { throw 'Tailscale must be installed and connected.' }
$tailStatus = & $tailscalePath status --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $tailStatus.BackendState -ne 'Running') { throw 'Connect Windows to Tailscale first.' }
$windowsIP = @($tailStatus.Self.TailscaleIPs | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)[0]
if (-not $windowsIP) { throw 'Windows has no Tailscale IPv4 address.' }
if ($beforeListener.Count -ne 1 -or $beforeListener[0] -ne ($windowsIP+':22')) { throw 'The SSH listener differs from the expected Tailscale-only listener; no settings were changed.' }
$configHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
$configAcl = (Get-Acl -LiteralPath $configPath).Sddl
$shellKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\OpenSSH')
try { $defaultShell = $shellKey.GetValue('DefaultShell') } finally { if ($shellKey) { $shellKey.Close() } }
$expectEnforced = if ($RestoreFrom) { [bool]$record.RuntimeEnforced } else { $false }
$registryChanged = $original.Exists -ne $desired.Exists -or $original.Base64 -ne $desired.Base64
if (-not $registryChanged -and $beforePolicy.EnforceRedirectionTrust -eq $expectEnforced) {
    Write-Output 'The requested SSH mitigation state is already active. No restart is necessary.'
    return
}

$backupPath = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
$backup = [ordered]@{
    Schema=1;CreatedAt=[DateTime]::UtcNow.ToString('o');UserSid=$identity.User.Value;RegistryPath=$registryPath
    OriginalExists=$original.Exists;OriginalBase64=$original.Base64;RuntimeEnforced=$beforePolicy.EnforceRedirectionTrust
    OriginalRuntimePolicy=$beforePolicy;SshConfigSha256=$configHash;DefaultShell=$defaultShell
}
[IO.File]::WriteAllText((Join-Path $backupPath 'settings.json'), ($backup | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
$writeKey = $null
$changed = $false
try {
    $writeKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($registryPath,$true)
    if (-not $writeKey) { throw 'Could not open the existing SSH mitigation key for writing.' }
    $changed = $true
    Write-MitigationRegistry $writeKey $desired
    $written = Read-MitigationRegistry $writeKey
    if ($written.Exists -ne $desired.Exists -or $written.Base64 -ne $desired.Base64) { throw 'Mitigation registry readback verification failed.' }
    Write-Output 'Restarting SSH once to apply the Scoop junction compatibility setting. Reconnect SSH and VS Code afterwards.'
    Restart-Service sshd -ErrorAction Stop
    Test-SameListener $beforeListener
    $afterPolicy = Get-ServiceRedirectionPolicy
    if ($afterPolicy.EnforceRedirectionTrust -ne $expectEnforced) { throw 'The running SSH process did not enter the requested RedirectionGuard state.' }
    if ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $configHash -or (Get-Acl -LiteralPath $configPath).Sddl -ne $configAcl) { throw 'SSH configuration or ACL changed unexpectedly during repair.' }
    $result = [ordered]@{
        success=$true;verifiedAt=[DateTime]::UtcNow.ToString('o');mode=$(if($RestoreFrom){'restored'}else{'repaired'})
        backupDirectory=$backupPath;previousPolicy=$beforePolicy;currentPolicy=$afterPolicy
        registryBefore=[BitConverter]::ToString($original.Bytes);registryAfter=[BitConverter]::ToString($written.Bytes)
        listener=$beforeListener;sshConfigurationPreserved=$true;defaultShell=$defaultShell
        sshdRestarted=$true;newSshConnectionRequired=$true;authenticationFirewallAndForwardingChanged=$false
    }
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $result | ConvertTo-Json -Depth 5
    Write-Output ('Undo: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Apply -RestoreFrom "'+$backupPath+'"')
} catch {
    $failure = $_
    if ($changed) {
        try {
            Write-MitigationRegistry $writeKey $original
            Restart-Service sshd -ErrorAction Stop
            Test-SameListener $beforeListener
        } catch { Write-Warning ('Restoring the previous mitigation/service state failed: '+$_.Exception.Message+'. Backup: '+$backupPath) }
    }
    throw $failure
} finally { if ($writeKey) { $writeKey.Close() } }
