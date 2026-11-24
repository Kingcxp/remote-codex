[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$RecoverOnly,
    [string]$PowerShellPath,
    [string]$RequiredVersion = '7.6.9',
    [string]$RestoreFrom
)
$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
$backupRoot = Join-Path $bundleRoot 'state\ssh-shell-backups'
$resultPath = Join-Path $bundleRoot 'state\ssh-shell-result.json'
$registrySubKey = 'SOFTWARE\OpenSSH'
$registryNames = @('DefaultShell', 'DefaultShellCommandOption')
$packageVersion = '7.6.9'
$packageName = 'PowerShell-7.6.9-win-x64.zip'
$packageSha256 = 'ce7484804c0f0ad4dda10c958e71acdaf7eebfb22505c1b480f89e0e9f1da94d'
$packageUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/PowerShell-7.6.9-win-x64.zip'
$packageCache = Join-Path $bundleRoot ('state\downloads\powershell\' + $packageName)
$managedRoot = Join-Path $env:ProgramData 'CodexPrivateSSH\PowerShell'
$managedVersionRoot = Join-Path $managedRoot $packageVersion
$managedExecutable = Join-Path $managedVersionRoot 'pwsh.exe'
$fallbackExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$safeRegistry = @(
    [pscustomobject]@{ Name='DefaultShell'; Exists=$true; Kind='String'; Value=$fallbackExecutable },
    [pscustomobject]@{ Name='DefaultShellCommandOption'; Exists=$true; Kind='String'; Value='-c' }
)

function Get-ShellRegistrySnapshot($Key) {
    $snapshot = @()
    foreach ($name in $registryNames) {
        $exists = $null -ne $Key -and $Key.GetValueNames() -contains $name
        $snapshot += [pscustomobject]@{
            Name = $name; Exists = $exists
            Value = $(if ($exists) { $Key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null })
            Kind = $(if ($exists) { [string]$Key.GetValueKind($name) } else { 'String' })
        }
    }
    return $snapshot
}

function Set-ShellRegistrySnapshot($Key, $Snapshot) {
    if (@($Snapshot).Count -ne 2 -or @($Snapshot.Name | Sort-Object -Unique).Count -ne 2) { throw 'Invalid SSH shell registry snapshot.' }
    foreach ($entry in $Snapshot) {
        if ($entry.Name -notin $registryNames) { throw 'Unexpected registry value in shell backup.' }
        if ($entry.Exists -and $entry.Kind -notin @('String', 'ExpandString')) { throw 'Unexpected registry value type in shell backup.' }
    }
    foreach ($entry in $Snapshot) {
        if ($entry.Exists) { $Key.SetValue($entry.Name, $entry.Value, [Microsoft.Win32.RegistryValueKind]([Enum]::Parse([Microsoft.Win32.RegistryValueKind], $entry.Kind))) }
        else { $Key.DeleteValue($entry.Name, $false) }
    }
}

function Find-InstalledPowerShell {
    $candidates = @()
    if ($PowerShellPath) { $candidates += $PowerShellPath }
    else {
        $candidates += $managedExecutable
        $candidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    }
    $probe = '[pscustomobject]@{ Version=$PSVersionTable.PSVersion.ToString(); Path=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } | ConvertTo-Json -Compress'
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        if ($candidate -match '(?i)[\\/]WindowsApps[\\/]') { throw 'Microsoft Store/MSIX PowerShell cannot be used as the SSH shell on this machine. Use the independent ZIP or MSI edition.' }
        try {
            $output = @(& $candidate -NoLogo -NoProfile -NonInteractive -Command $probe 2>$null)
            if ($LASTEXITCODE -ne 0) { continue }
            $info = ($output -join "`n") | ConvertFrom-Json
            if ($info.Version -ne $RequiredVersion -or -not [IO.Path]::IsPathRooted($info.Path) -or -not (Test-Path -LiteralPath $info.Path -PathType Leaf)) { continue }
            if ($info.Path -match '(?i)[\\/]\.cache[\\/]codex-runtimes[\\/]') { throw 'The embedded Codex runtime cannot be used as the SSH shell.' }
            if ($info.Path -match '(?i)[\\/]WindowsApps[\\/]') { throw 'Microsoft Store/MSIX PowerShell cannot be used as the SSH shell on this machine.' }
            return $info
        } catch { if ($PowerShellPath) { throw } }
    }
    if ($PowerShellPath -or $RequiredVersion -ne $packageVersion) { throw ('Independent PowerShell ' + $RequiredVersion + ' was not found. Pass -PowerShellPath pointing to a ZIP/MSI edition of the required version.') }
    return [pscustomobject]@{ Version=$packageVersion; Path=$managedExecutable; RequiresInstall=$true }
}

function Protect-PowerShellDirectory([string]$Path) {
    if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The managed PowerShell directory cannot be a reparse point.' }
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not protect the standalone PowerShell installation directory.' }
    foreach ($rule in @((Get-Acl -LiteralPath $Path).Access)) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -notin @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')) {
            & icacls.exe $Path /remove ('*' + $sid) | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Could not restrict the standalone PowerShell directory ACL.' }
        }
    }
    & icacls.exe $Path /setowner '*S-1-5-32-544' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not set the standalone PowerShell directory owner.' }
}

function Install-IndependentPowerShell {
    if (-not (Test-Path -LiteralPath $packageCache -PathType Leaf)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $packageCache) -Force | Out-Null
        Write-Output 'Downloading the official standalone PowerShell ZIP (about 110 MB)...' | Out-Host
        $partialPath = $packageCache + '.download'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $packageUrl -OutFile $partialPath
        if ((Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $packageSha256) { throw 'The official PowerShell ZIP failed its pinned SHA256 check.' }
        Move-Item -LiteralPath $partialPath -Destination $packageCache -Force
    }
    if ((Get-FileHash -LiteralPath $packageCache -Algorithm SHA256).Hash.ToLowerInvariant() -ne $packageSha256) { throw 'The cached PowerShell ZIP failed its pinned SHA256 check.' }
    New-Item -ItemType Directory -Path $managedRoot -Force | Out-Null
    Protect-PowerShellDirectory $managedRoot
    if (Test-Path -LiteralPath $managedVersionRoot) { throw 'An incomplete managed PowerShell installation already exists; it was preserved for inspection.' }
    $stage = Join-Path $managedRoot ('.install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    Protect-PowerShellDirectory $stage
    Expand-Archive -LiteralPath $packageCache -DestinationPath $stage
    $stageExecutable = Join-Path $stage 'pwsh.exe'
    $signature = Get-AuthenticodeSignature -FilePath $stageExecutable
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|, )O=Microsoft Corporation(?:,|$)') { throw 'Standalone pwsh.exe is not signed by Microsoft with a valid signature.' }
    $versionOutput = @(& $stageExecutable -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null)
    if ($LASTEXITCODE -ne 0 -or ($versionOutput -join '').Trim() -ne $packageVersion) { throw 'The independent PowerShell version check failed.' }
    [IO.File]::WriteAllText((Join-Path $stage 'codex-ssh-runtime.json'), ([ordered]@{Version=$packageVersion;Source=$packageUrl;Sha256=$packageSha256;VerifiedAt=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $stage -Destination $managedVersionRoot
    return $managedExecutable
}

function Test-ServiceSessionPowerShell([string]$Executable, [string]$ExpectedVersion) {
    # A temporary SYSTEM task exercises Windows Session 0, where sshd launches
    # shells. This catches MSIX cross-session activation failures before commit.
    $probeDirectory = Join-Path $managedRoot ('.probe-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probeDirectory | Out-Null
    Protect-PowerShellDirectory $probeDirectory
    $probeResult = Join-Path $probeDirectory 'result.json'
    $escapedResult = $probeResult.Replace("'", "''")
    $probeScript = '$ErrorActionPreference="Stop"; $probe=[ordered]@{Version=$PSVersionTable.PSVersion.ToString();Path=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;SessionId=(Get-Process -Id $PID).SessionId;Identity=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}; [IO.File]::WriteAllText(''' + $escapedResult + ''',($probe|ConvertTo-Json -Compress));'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeScript))
    $taskName = 'CodexSshPowerShellProbe-' + [Guid]::NewGuid().ToString('N')
    $registered = $false
    $result = $null
    try {
        $action = New-ScheduledTaskAction -Execute $Executable -Argument ('-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded) -WorkingDirectory (Split-Path -Parent $Executable)
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 30)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings | Out-Null
        $registered = $true
        Start-ScheduledTask -TaskName $taskName
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $probeResult -PathType Leaf) {
                try { $result = Get-Content -LiteralPath $probeResult -Raw | ConvertFrom-Json; break } catch { }
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $result -or $result.Version -ne $ExpectedVersion -or $result.Path -ne $Executable -or $result.SessionId -ne 0 -or $result.Identity -ne 'S-1-5-18') {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
            throw ('PowerShell did not pass the Session 0 startup probe. Task result: ' + $taskInfo.LastTaskResult)
        }
        return $result
    } finally {
        if ($registered) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if ($Apply -and -not $elevated) { throw 'Run this command in a Windows administrator PowerShell or in your existing administrator SSH session. Updating HKLM requires administrator rights; no settings have been changed.' }
$readKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($registrySubKey)
try { $originalRegistry = @(Get-ShellRegistrySnapshot $readKey) } finally { if ($readKey) { $readKey.Close() } }

$shell = $null
if ($RecoverOnly -and $RestoreFrom) { throw 'Choose RecoverOnly or RestoreFrom, not both.' }
if ($RecoverOnly) {
    $desiredRegistry = $safeRegistry
} elseif ($RestoreFrom) {
    $restorePath = (Resolve-Path -LiteralPath $RestoreFrom).Path
    $canonicalBackupRoot = [IO.Path]::GetFullPath($backupRoot).TrimEnd('\') + '\'
    if (-not $restorePath.StartsWith($canonicalBackupRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'RestoreFrom must be a backup from state\ssh-shell-backups.' }
    $record = Get-Content -LiteralPath (Join-Path $restorePath 'settings.json') -Raw | ConvertFrom-Json
    if ($record.Schema -ne 1 -or $record.UserSid -ne $identity.User.Value) { throw 'The shell backup does not match this account.' }
    $desiredRegistry = @($record.Registry)
    $restoreShell = ($desiredRegistry | Where-Object Name -eq 'DefaultShell').Value
    if ($restoreShell -match '(?i)[\\/]WindowsApps[\\/]') { throw 'This backup points to the broken Store/MSIX shell. Use -Apply -RecoverOnly to restore the Windows system PowerShell.' }
} else {
    $shell = Find-InstalledPowerShell
    $desiredRegistry = @(
        [pscustomobject]@{ Name = 'DefaultShell'; Exists = $true; Kind = 'String'; Value = $shell.Path },
        [pscustomobject]@{ Name = 'DefaultShellCommandOption'; Exists = $true; Kind = 'String'; Value = '-c' }
    )
}
if (-not $Apply) {
    [pscustomobject]@{
        Mode = 'PREVIEW ONLY'; PowerShellVersion = $(if ($shell) { $shell.Version } else { $null })
        ProposedRegistry = $desiredRegistry; CurrentRegistry = $originalRegistry
        IndependentPackageCached = (Test-Path -LiteralPath $packageCache -PathType Leaf)
        ServiceSessionProbe = 'A temporary SYSTEM scheduled task validates Session 0 startup before selecting PowerShell 7.'
        Elevated = $elevated; SudoChanged = $false; PowerShellProfilesChanged = $false
        ApplyCommand = 'Run this script with -Apply in an administrator PowerShell or your existing administrator SSH session.'
    } | ConvertTo-Json -Depth 5
    return
}

$backupPath = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
$backupRecord = [ordered]@{ Schema = 1; CreatedAt = [DateTime]::UtcNow.ToString('o'); UserSid = $identity.User.Value; Registry = $originalRegistry }
[IO.File]::WriteAllText((Join-Path $backupPath 'settings.json'), ($backupRecord | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
$writeKey = $null
$changed = $false
$serviceProbe = $null
try {
    $writeKey = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($registrySubKey)
    $changed = $true
    # Recover access immediately, and never roll back to a failed MSIX shell.
    Set-ShellRegistrySnapshot $writeKey $safeRegistry
    if ($shell) {
        if ($shell.PSObject.Properties['RequiresInstall'] -and $shell.RequiresInstall) {
            [void](Install-IndependentPowerShell)
            $shell = Find-InstalledPowerShell
            $desiredRegistry[0].Value = $shell.Path
        }
        New-Item -ItemType Directory -Path $managedRoot -Force | Out-Null
        Protect-PowerShellDirectory $managedRoot
        $serviceProbe = Test-ServiceSessionPowerShell $shell.Path $RequiredVersion
    }
    Set-ShellRegistrySnapshot $writeKey $desiredRegistry
    $written = @(Get-ShellRegistrySnapshot $writeKey)
    foreach ($expected in $desiredRegistry) {
        $actual = $written | Where-Object Name -eq $expected.Name
        if ($actual.Exists -ne $expected.Exists -or ($expected.Exists -and ($actual.Kind -ne $expected.Kind -or $actual.Value -ne $expected.Value))) { throw 'The SSH default shell registry verification failed.' }
    }
    $result = [ordered]@{
        success = $true; verifiedAt = [DateTime]::UtcNow.ToString('o'); mode = $(if ($RecoverOnly) { 'recovered' } elseif ($RestoreFrom) { 'restored' } else { 'configured' })
        account = $identity.Name; powerShellVersion = $(if ($shell) { $shell.Version } else { $null })
        defaultShell = ($written | Where-Object Name -eq 'DefaultShell').Value; backupDirectory = $backupPath
        sudoChanged = $false; powerShellProfilesChanged = $false; sshdRestarted = $false; newSshSessionRequired = $true
        serviceSessionProbe = $serviceProbe; packageSha256 = $packageSha256
    }
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    $result | ConvertTo-Json -Depth 4
    Write-Output 'Open a NEW SSH connection to use the configured shell. Existing SSH connections and tunnels were not restarted.'
    Write-Output ('Recovery: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Apply -RecoverOnly')
} catch {
    $failure = $_
    if ($changed) {
        try {
            Set-ShellRegistrySnapshot $writeKey $safeRegistry
            Write-Warning 'PowerShell 7 configuration failed. SSH was recovered to the built-in Windows PowerShell 5.1. Open a new connection.'
        } catch { Write-Warning ('Automatic SSH recovery failed: ' + $_.Exception.Message + '. Backup: ' + $backupPath) }
    }
    throw $failure
} finally { if ($writeKey) { $writeKey.Close() } }
