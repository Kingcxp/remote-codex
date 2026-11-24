[CmdletBinding()]
param(
    [string]$ArchIP,
    [string]$AndroidIP,
    [AllowEmptyCollection()][string[]]$AllowedClientIPs,
    [string]$SourcePath,
    [switch]$DisableDirect,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
if ((Test-Path -LiteralPath (Join-Path $bundleRoot 'state\access-devices.json')) -and -not $PSBoundParameters.ContainsKey('AllowedClientIPs') -and -not $DisableDirect) { throw 'A multi-device profile exists. Use Setup.ps1 to preserve all devices, or explicitly supply the complete -AllowedClientIPs list.' }
$sourceExe = Join-Path $env:USERPROFILE 'scoop\apps\rustdesk\1.5.1\RustDesk.exe'
if ($SourcePath) { $sourceExe = [IO.Path]::GetFullPath($SourcePath) }
$expectedHash = '319206042390ebfcba934cf0baa2f612f34de463c78c843b7cb8c22097c4bf7b'
$installedExe = Join-Path $env:ProgramFiles 'RustDesk\RustDesk.exe'
$ruleName = 'CodexRemote-RustDesk-Tailscale'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$administrator = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Assert-TailIP([string]$Value) {
    $address = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$address) -or $address.AddressFamily -ne 'InterNetwork' -or $address.ToString() -ne $Value) { throw 'Use a single canonical Tailscale IPv4 address.' }
    $bytes = $address.GetAddressBytes()
    if ($bytes[0] -ne 100 -or $bytes[1] -lt 64 -or $bytes[1] -gt 127) { throw 'The client IP must be in 100.64.0.0/10.' }
}
function Assert-SignedRustDesk([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)(?:CN|O)=PURSLANE(?:,|$)') { throw ('RustDesk must have a valid PURSLANE signature: ' + $Path) }
}
function Invoke-RustDeskCli([string]$Path, [string[]]$CliArguments, [switch]$NoCapture) {
    # No password is passed to this function or to a process command line.
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Path
    # Windows argv quoting; no shell expansion, including for empty old option values.
    $startInfo.Arguments = (@($CliArguments | ForEach-Object {
        $escaped = [regex]::Replace($_, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = -not $NoCapture
    $startInfo.RedirectStandardError = -not $NoCapture
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        if ($NoCapture) {
            # Install/service commands spawn a persistent tray which inherits stdout handles.
            # Never read redirected pipes or use Start-Process -Wait (which waits for the tree).
            $finished = $false
            for ($second = 0; $second -lt 180; $second++) {
                if ($process.WaitForExit(1000)) { $finished = $true; break }
                if (($second + 1) % 30 -eq 0) { Write-Host 'Waiting for the local RustDesk installer/service command...' }
            }
            if (-not $finished) { $process.Kill(); throw 'RustDesk installer/service command timed out after 180 seconds.' }
            if ($process.ExitCode -ne 0) { throw ('RustDesk installer/service command failed: ' + $process.ExitCode) }
            return ''
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'RustDesk command timed out.' }
        if (-not $stdout.Wait(3000) -or -not $stderr.Wait(3000)) { throw 'RustDesk kept a command output pipe open. Installer/service commands must use NoCapture.' }
        $outText = $stdout.GetAwaiter().GetResult()
        $errText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw ('RustDesk command failed with exit code ' + $process.ExitCode + '. ' + $errText.Trim()) }
        # The official Windows portable launcher emits these startup diagnostics on stdout.
        # Strip only those known lines; unexpected output still makes read-back validation fail.
        return (@($outText -split '\r?\n' | Where-Object { $_ -notmatch '^(executing |Windows version: |is windows7: |skip \.\\)' }) -join "`n").Trim()
    } finally { $process.Dispose() }
}
function Protect-Backup([string]$Directory) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidText in @($identity.User.Value, 'S-1-5-18', 'S-1-5-32-544' | Select-Object -Unique)) {
        $sid = New-Object Security.Principal.SecurityIdentifier($sidText)
        $access = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        [void]$acl.AddAccessRule($access)
    }
    $acl.SetOwner($identity.User)
    Set-Acl -LiteralPath $Directory -AclObject $acl
}
function Get-RustDeskInboundRules {
    $result = @()
    foreach ($rule in @(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Inbound)) {
        if ($rule.Name -eq $ruleName) { $result += $rule; continue }
        if ($rule.Action -ne 'Allow') { continue }
        if ($rule.DisplayName -eq 'RustDesk Service' -or $rule.DisplayName -eq 'RustDesk via Tailscale') { $result += $rule; continue }
        $programs = @($rule | Get-NetFirewallApplicationFilter | Select-Object -ExpandProperty Program)
        if (@($programs | Where-Object { $_ -and ([IO.Path]::GetFileName($_) -ieq 'RustDesk.exe') }).Count) { $result += $rule }
    }
    return $result
}
function Get-ManagedRuleSnapshot($Rule) {
    $ports = $Rule | Get-NetFirewallPortFilter
    $addresses = $Rule | Get-NetFirewallAddressFilter
    $application = $Rule | Get-NetFirewallApplicationFilter
    $interface = $Rule | Get-NetFirewallInterfaceFilter
    return @{
        Name = $Rule.Name; NewDisplayName = $Rule.DisplayName; Enabled = [string]$Rule.Enabled
        Direction = [string]$Rule.Direction; Action = [string]$Rule.Action; Profile = [string]$Rule.Profile
        Protocol = $ports.Protocol; LocalPort = $ports.LocalPort
        LocalAddress = $addresses.LocalAddress; RemoteAddress = $addresses.RemoteAddress
        Program = $application.Program; InterfaceAlias = $interface.InterfaceAlias
    }
}

$clientIPs = @()
if (-not $DisableDirect) {
    if ($PSBoundParameters.ContainsKey('AllowedClientIPs')) { $clientIPs = @($AllowedClientIPs | Sort-Object -Unique) }
    else { $clientIPs = @($ArchIP, $AndroidIP | Sort-Object -Unique) }
    if (-not $clientIPs.Count) { throw 'An empty whitelist is unsafe. Use -DisableDirect to revoke the last device.' }
    foreach ($clientIP in $clientIPs) { Assert-TailIP $clientIP }
}
$tsPath = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
if (-not (Test-Path -LiteralPath $tsPath)) { throw 'Tailscale is not installed.' }
$tailnet = & $tsPath status --json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $tailnet.BackendState -ne 'Running') { throw 'Connect Windows to Tailscale first.' }
$windowsIP = @($tailnet.Self.TailscaleIPs | Where-Object { $_ -match '^100\.' })[0]
Assert-TailIP $windowsIP
if ($clientIPs -contains $windowsIP) { throw 'The host and client addresses must be different.' }
$settings = [ordered]@{
    'direct-server' = $(if($DisableDirect){'N'}else{'Y'})
    'direct-access-port' = '21118'
    # RustDesk treats an empty whitelist as unrestricted. A disabled host uses its own IP as a non-empty placeholder.
    'whitelist' = $(if($DisableDirect){$windowsIP}else{$clientIPs -join ','})
    'approve-mode' = 'password'
    'verification-method' = 'use-permanent-password'
    'allow-logon-screen-password' = 'Y'
    'allow-only-conn-window-open' = 'N'
    'enable-lan-discovery' = 'N'
    'allow-remote-config-modification' = 'N'
}
$existingService = Get-Service -Name RustDesk -ErrorAction SilentlyContinue
if (-not $Apply) {
    [pscustomobject]@{
        PreviewOnly = $true
        Administrator = $administrator
        SourceBinaryPresent = (Test-Path -LiteralPath $sourceExe)
        InstalledBinaryPresent = (Test-Path -LiteralPath $installedExe)
        ServiceState = $(if ($existingService) { [string]$existingService.Status } else { 'NotInstalled' })
        Destination = ($windowsIP + ':21118')
        AllowedClients = @($clientIPs)
        Settings = $settings
        PasswordEntry = 'Set a permanent password privately in RustDesk Settings > Security after Apply.'
        ApplyRequiresAdministrator = 'Install/start the machine service, change its security settings and scope Windows Firewall.'
    } | ConvertTo-Json -Depth 5
    return
}
if (-not $administrator) { throw 'Run this command in an Administrator PowerShell. Installing a system service and changing Windows Firewall require elevation.' }
if ($DisableDirect -and -not (Test-Path -LiteralPath $installedExe)) {
    Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue | Disable-NetFirewallRule | Out-Null
    Write-Output 'RustDesk is not installed; its managed direct-access firewall rule is disabled.'
    return
}
$profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
if (@($profiles | Where-Object { -not $_.Enabled -or $_.DefaultInboundAction -eq 'Allow' }).Count) { throw 'Windows Firewall must be enabled and block unsolicited inbound connections before applying.' }
if (-not (Test-Path -LiteralPath $installedExe)) {
    if (-not (Test-Path -LiteralPath $sourceExe)) { throw 'Install RustDesk from https://rustdesk.com/ first, or supply -SourcePath to its official signed executable.' }
    Assert-SignedRustDesk $sourceExe
    if (-not $SourcePath -and (Get-FileHash -LiteralPath $sourceExe).Hash.ToLowerInvariant() -ne $expectedHash) { throw 'The Scoop RustDesk executable does not match the verified 1.5.1 SHA256. Supply an explicitly selected official signed installer with -SourcePath instead.' }
}
$backupRoot = Join-Path $bundleRoot 'state\rustdesk-backups'
[void](New-Item -ItemType Directory -Path $backupRoot -Force)
Protect-Backup $backupRoot
$backupDirectory = Join-Path $backupRoot ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
[void](New-Item -ItemType Directory -Path $backupDirectory)
$oldRules = @(Get-RustDeskInboundRules)
$oldRules | Select-Object Name, Enabled | Export-Clixml -LiteralPath (Join-Path $backupDirectory 'firewall-enabled.xml')
$oldServiceInfo = Get-CimInstance Win32_Service -Filter "Name='RustDesk'"
$oldManagedRule = $oldRules | Where-Object Name -eq $ruleName | Select-Object -First 1
$oldManagedSnapshot = if ($oldManagedRule) { Get-ManagedRuleSnapshot $oldManagedRule } else { $null }
if ($oldManagedSnapshot) { Export-Clixml -InputObject $oldManagedSnapshot -LiteralPath (Join-Path $backupDirectory 'managed-firewall.xml') }
$oldOptions = [ordered]@{}
$installedNow = $false
$createdRule = $false
$optionsChanged = $false
try {
    # Save private config files without printing their contents.
    $configRoots = @(
        (Join-Path $env:APPDATA 'RustDesk\config'),
        (Join-Path $env:WINDIR 'ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config'),
        (Join-Path $env:WINDIR 'System32\config\systemprofile\AppData\Roaming\RustDesk\config')
    )
    for ($index = 0; $index -lt $configRoots.Count; $index++) {
        foreach ($fileName in @('RustDesk.toml', 'RustDesk2.toml')) {
            $configFile = Join-Path $configRoots[$index] $fileName
            if (Test-Path -LiteralPath $configFile) { Copy-Item -LiteralPath $configFile -Destination (Join-Path $backupDirectory ($index.ToString() + '-' + $fileName)) }
        }
    }
    if (-not (Test-Path -LiteralPath $installedExe)) {
        Write-Output 'Installing the signed RustDesk client and service into Program Files (no additional download).'
        $installedNow = $true
        $null = Invoke-RustDeskCli $sourceExe @('--silent-install', 'printer=0') -NoCapture
        if (-not (Test-Path -LiteralPath $installedExe)) { throw 'The installer did not create Program Files\RustDesk\RustDesk.exe.' }
    }
    Assert-SignedRustDesk $installedExe
    if (-not (Get-Service -Name RustDesk -ErrorAction SilentlyContinue)) { $null = Invoke-RustDeskCli $installedExe @('--install-service') -NoCapture }
    Set-Service -Name RustDesk -StartupType Automatic
    Start-Service -Name RustDesk
    (Get-Service -Name RustDesk).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='RustDesk'"
    if ($serviceInfo.PathName -notmatch ('^"?' + [regex]::Escape($installedExe) + '"?\s+--service\s*$')) { throw 'The RustDesk service points to a different executable. Review its PathName before proceeding.' }
    # RustDesk's supported --option CLI talks to the running host and preserves unrelated options.
    foreach ($name in $settings.Keys) { $oldOptions[$name] = Invoke-RustDeskCli $installedExe @('--option', $name) }
    [IO.File]::WriteAllText((Join-Path $backupDirectory 'options.json'), ($oldOptions | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    # Apply authentication and whitelist before enabling the direct listener.
    $optionsChanged = $true
    foreach ($name in @($settings.Keys | Where-Object { $_ -ne 'direct-server' }) + @('direct-server')) {
        $null = Invoke-RustDeskCli $installedExe @('--option', $name, $settings[$name])
        $actual = Invoke-RustDeskCli $installedExe @('--option', $name)
        if ($actual -ne $settings[$name]) { throw ('RustDesk did not accept setting: ' + $name) }
    }
    # Scope only RustDesk's own inbound rules, including any rule created by its installer.
    foreach ($rule in @(Get-RustDeskInboundRules)) { $rule | Disable-NetFirewallRule | Out-Null }
    $addressInfo = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $windowsIP | Select-Object -First 1
    $ruleParameters = @{ Name = $ruleName; DisplayName = 'RustDesk via Tailscale (managed devices)'; Direction = 'Inbound'; Action = 'Allow'; Enabled = $(if($DisableDirect){'False'}else{'True'}); Profile = 'Any'; Protocol = 'TCP'; LocalPort = 21118; LocalAddress = $windowsIP; RemoteAddress = $(if($DisableDirect){@($windowsIP)}else{@($clientIPs)}); InterfaceAlias = $addressInfo.InterfaceAlias; Program = $installedExe }
    if ($oldManagedRule) {
        $ruleParameters.NewDisplayName = $ruleParameters.DisplayName
        $ruleParameters.Remove('DisplayName')
        Set-NetFirewallRule @ruleParameters | Out-Null
    }
    else { New-NetFirewallRule @ruleParameters | Out-Null; $createdRule = $true }
    $listener = $null
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort 21118 -ErrorAction SilentlyContinue
        if (($listener -and -not $DisableDirect) -or (-not $listener -and $DisableDirect)) { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $DisableDirect -and -not $listener) { throw 'RustDesk did not open its TCP 21118 listener.' }
    if ($DisableDirect -and $listener) { throw 'RustDesk did not close its TCP 21118 listener.' }
    $owners = @($listener | Select-Object -ExpandProperty OwningProcess -Unique)
    foreach ($ownerId in $owners) {
        $ownerProcess = Get-Process -Id $ownerId
        if ([IO.Path]::GetFileName($ownerProcess.Path) -ine 'RustDesk.exe') { throw 'TCP 21118 is owned by another application.' }
    }
    $result = [ordered]@{ ConfiguredAt = [DateTime]::UtcNow.ToString('o'); Destination = ($windowsIP + ':21118'); AllowedClients = @($clientIPs); DirectEnabled = (-not $DisableDirect); ServiceRunning = $true; ListenerVerified = $true; SettingsVerified = $true; PasswordHandledByScript = $false; BackupDirectory = $backupDirectory }
    [IO.File]::WriteAllText((Join-Path $bundleRoot 'state\rustdesk-result.json'), ($result | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $result | ConvertTo-Json
    if (-not $DisableDirect) { Write-Output 'NEXT: Open the installed RustDesk > Settings > Security and set your permanent password. Do not send the password in chat.' }
    Write-Output 'Allow TCP 21118 from these client IPs in the Tailscale policy if your current policy restricts ports. See docs\RUSTDESK.zh-CN.md.'
} catch {
    $failure = $_
    Write-Warning ('Configuration failed; restoring previous settings. Backup: ' + $backupDirectory)
    if ($optionsChanged) {
        foreach ($name in $oldOptions.Keys) {
            try {
                $null = Invoke-RustDeskCli $installedExe @('--option', $name, [string]$oldOptions[$name])
            } catch { Write-Warning ('Could not restore option ' + $name + ': ' + $_.Exception.Message) }
        }
    }
    if ($createdRule) { Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue }
    if ($oldManagedSnapshot) { try { Set-NetFirewallRule @oldManagedSnapshot | Out-Null } catch { Write-Warning 'Could not fully restore the previous managed firewall rule.' } }
    foreach ($newRule in @(Get-RustDeskInboundRules | Where-Object { $_.Name -notin @($oldRules.Name) })) {
        $newRule | Disable-NetFirewallRule -ErrorAction SilentlyContinue | Out-Null
    }
    foreach ($oldRule in $oldRules) {
        try { Set-NetFirewallRule -Name $oldRule.Name -Enabled $oldRule.Enabled | Out-Null } catch { Write-Warning ('Could not restore firewall rule: ' + $oldRule.Name) }
    }
    if ($installedNow -or -not $existingService) {
        Stop-Service -Name RustDesk -ErrorAction SilentlyContinue
        Set-Service -Name RustDesk -StartupType Disabled -ErrorAction SilentlyContinue
        Get-Process -Name RustDesk -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $installedExe } | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Warning 'RustDesk remains installed; its newly created service has been stopped and disabled. Run Apply again after fixing the error.'
    } elseif ($oldServiceInfo) {
        try {
            $startupType = switch ($oldServiceInfo.StartMode) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { throw 'Unknown previous service startup mode.' } }
            Set-Service -Name RustDesk -StartupType $startupType
            if ($oldServiceInfo.State -eq 'Running') { Start-Service -Name RustDesk }
            else { Stop-Service -Name RustDesk -ErrorAction SilentlyContinue }
        } catch { Write-Warning ('Could not restore service state: ' + $_.Exception.Message) }
    }
    throw $failure
}
