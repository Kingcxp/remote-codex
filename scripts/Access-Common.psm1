Set-StrictMode -Version 2

function Assert-TailAddress([string]$Value) {
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork' -or $ip.ToString() -cne $Value) { throw 'Expected one canonical Tailscale IPv4 address.' }
    $b = $ip.GetAddressBytes()
    if ($b[0] -ne 100 -or $b[1] -lt 64 -or $b[1] -gt 127) { throw 'Only Tailscale 100.64.0.0/10 addresses are allowed.' }
    return $Value
}

function ConvertTo-PublicKey([string]$Text) {
    $line = $Text.Trim()
    if ($line -notmatch '^ssh-ed25519\s+([A-Za-z0-9+/]+={0,2})(?: [^\r\n]*)?$') { throw 'Provide ONE ssh-ed25519 PUBLIC key, never a private key or a command.' }
    $encoded = $Matches[1]
    $bytes = [Convert]::FromBase64String($encoded)
    if ($bytes.Length -ne 51 -or [BitConverter]::ToString($bytes[0..3]) -ne '00-00-00-0B' -or [Text.Encoding]::ASCII.GetString($bytes,4,11) -ne 'ssh-ed25519' -or [BitConverter]::ToString($bytes[15..18]) -ne '00-00-00-20') { throw 'Invalid Ed25519 public key encoding.' }
    return ('ssh-ed25519 ' + [Convert]::ToBase64String($bytes))
}

function ConvertTo-IPv4Number([string]$Address) {
    $b = ([Net.IPAddress]::Parse($Address)).GetAddressBytes()
    return ([uint64]$b[0] * 16777216 + [uint64]$b[1] * 65536 + [uint64]$b[2] * 256 + [uint64]$b[3])
}
function ConvertFrom-IPv4Number([uint64]$Number) {
    return ('{0}.{1}.{2}.{3}' -f ([math]::Floor($Number / 16777216) % 256), ([math]::Floor($Number / 65536) % 256), ([math]::Floor($Number / 256) % 256), ($Number % 256))
}
function Get-BlockedIPv4Ranges([string[]]$Allowed) {
    # Windows explicit Block wins over Allow. Recompute the complement whenever a client changes.
    $numbers = @($Allowed | ForEach-Object { ConvertTo-IPv4Number (Assert-TailAddress $_) } | Sort-Object -Unique)
    [uint64]$next = 0
    foreach ($n in $numbers) {
        if ($n -gt $next) { (ConvertFrom-IPv4Number $next) + '-' + (ConvertFrom-IPv4Number ($n - 1)) }
        $next = $n + 1
    }
    if ($next -le 4294967295) { (ConvertFrom-IPv4Number $next) + '-255.255.255.255' }
}

function Write-AccessJson([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Get-TailscaleExecutable {
    $candidate = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'Tailscale is not installed. Install it from https://tailscale.com/download/windows and sign in.'
}
function Get-AccessTailnet {
    $exe = Get-TailscaleExecutable
    $raw = & $exe status --json
    if ($LASTEXITCODE -ne 0) { throw 'Tailscale status failed. Start Tailscale and sign in.' }
    $status = $raw | ConvertFrom-Json
    if ($status.BackendState -ne 'Running') { throw 'Tailscale is not connected. Open Tailscale, sign in and connect.' }
    $ip = @($status.Self.TailscaleIPs | Where-Object { $_ -match '^100\.' }) | Select-Object -First 1
    [void](Assert-TailAddress $ip)
    $dns = ([string]$status.Self.DNSName).TrimEnd('.')
    if ($dns -notmatch '^[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]+\.ts\.net$') { throw 'Enable MagicDNS and HTTPS in this tailnet before continuing.' }
    $peers = @()
    if ($status.Peer) { $peers = @($status.Peer.PSObject.Properties | ForEach-Object { $_.Value }) }
    [pscustomobject]@{ Executable=$exe; IP=$ip; DNS=$dns; NodeId=[string]$status.Self.ID; Peers=$peers }
}
function Assert-PrivateServe($Tailnet) {
    $text = & $Tailnet.Executable serve status --json
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Tailscale Serve.' }
    $serve = $text | ConvertFrom-Json
    $property = $serve.PSObject.Properties['AllowFunnel']
    if ($property -and $property.Value -and @($property.Value.PSObject.Properties | Where-Object { $_.Value -eq $true }).Count) { throw 'Funnel is enabled. Disable public Funnel before using this private-access wizard.' }
}
function Get-AccessHostFingerprint([string]$Root) {
    $saved = Join-Path $Root 'state\onboarding\ssh-host-fingerprint.txt'
    if (Test-Path -LiteralPath $saved) {
        $value = (Get-Content -LiteralPath $saved -Raw).Trim()
        if ($value -match '^SHA256:[A-Za-z0-9+/]{43}$') { return [string]$value }
    }
    # A host public key is public. No private key or elevated read is needed for this fallback.
    try {
        $text = & (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe') -lf (Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key.pub') 2>$null
        if ($LASTEXITCODE -eq 0 -and $text -match '(SHA256:[A-Za-z0-9+/]{43})') { return $Matches[1] }
    } catch { }
    return ''
}

function Assert-AccessProfile($Profile) {
    if ($Profile.schemaVersion -ne 1) { throw 'Unsupported device profile schema.' }
    [void](Assert-TailAddress $Profile.host.IP)
    if ($Profile.host.DNS -notmatch '^[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]+\.ts\.net$' -or $Profile.host.User -cnotmatch '^[a-z0-9_.-]+$') { throw 'Invalid host DNS name or local SSH user.' }
    if ([int]$Profile.host.Port -ne 3300) { throw 'This wizard currently supports the bundled bridge port 3300.' }
    $ids = @{}; $ips = @{}; $nodes = @{}; $keys = @{}
    foreach ($device in @($Profile.devices)) {
        if ($device.Id -cnotmatch '^[0-9a-f]{32}$' -or $ids.ContainsKey($device.Id)) { throw 'Invalid or duplicate device ID.' }
        $ids[$device.Id] = $true
        [void](Assert-TailAddress $device.IP)
        if ($device.IP -eq $Profile.host.IP -or $ips.ContainsKey($device.IP)) { throw 'Duplicate device IP or host selected as client.' }
        $ips[$device.IP] = $true
        if ($device.NodeId) {
            if ($nodes.ContainsKey($device.NodeId)) { throw 'Duplicate Tailscale node.' }
            $nodes[$device.NodeId] = $true
        }
        if ($device.Name.Length -lt 1 -or $device.Name.Length -gt 100 -or $device.Name -match '[\x00-\x1f\x7f]') { throw 'Invalid device label.' }
        foreach ($flag in @('Codex','Ssh','RustDesk','LegacySsh')) { if ($device.$flag -isnot [bool]) { throw ('Invalid boolean: ' + $flag) } }
        if ($device.Ssh -and -not $device.LegacySsh) {
            $normalized = ConvertTo-PublicKey $device.PublicKey
            if ($keys.ContainsKey($normalized)) { throw 'Use a different SSH key on each device.' }
            $keys[$normalized] = $true
        }
        if (-not $device.LegacySsh -and -not $device.Ssh -and $device.PublicKey) { throw 'An SSH key requires SSH permission.' }
        foreach ($id in @($device.BrowserIds)) { if ($id -notmatch '^[a-zA-Z0-9_.:-]{1,160}$') { throw 'Invalid browser identity.' } }
    }
}

function Get-AccessProfile([string]$Root, $Tailnet) {
    $path = Join-Path $Root 'state\access-devices.json'
    if (Test-Path -LiteralPath $path) {
        $profile = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-AccessProfile $profile
        if ($profile.host.NodeId -ne $Tailnet.NodeId -or $profile.host.IP -ne $Tailnet.IP -or $profile.host.DNS -ne $Tailnet.DNS) { throw 'This saved profile belongs to a different Tailscale host/address. Do not copy state/ to another machine. See the onboarding guide.' }
        return $profile
    }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name.Split('\')[-1].ToLowerInvariant()
    $sshIPs = @(); $rustIPs = @()
    foreach ($item in @(@('CodexPrivateSSH-Allow','ssh'), @('CodexRemote-RustDesk-Tailscale','rust'))) {
        $rule = Get-NetFirewallRule -Name $item[0] -ErrorAction SilentlyContinue
        if ($rule -and [string]$rule.Enabled -eq 'True') {
            $addresses = @($rule | Get-NetFirewallAddressFilter | Select-Object -ExpandProperty RemoteAddress)
            foreach ($address in $addresses) { [void](Assert-TailAddress $address) }
            if ($item[1] -eq 'ssh') { $sshIPs = $addresses } else { $rustIPs = $addresses }
        }
    }
    $devices = @()
    foreach ($ip in @(@($sshIPs) + @($rustIPs) | Sort-Object -Unique)) {
        $peer = @($Tailnet.Peers | Where-Object { $_.TailscaleIPs -contains $ip }) | Select-Object -First 1
        $devices += [pscustomobject]@{ Id=[Guid]::NewGuid().ToString('N'); NodeId=$(if($peer){[string]$peer.ID}else{''}); Name=$(if($peer){[string]$peer.HostName}else{'Existing ' + $ip}); Platform=$(if($peer){[string]$peer.OS}else{'unknown'}); IP=$ip; Codex=$true; Ssh=($sshIPs -contains $ip); RustDesk=($rustIPs -contains $ip); LegacySsh=($sshIPs -contains $ip); PublicKey=''; BrowserIds=@() }
    }
    $profile = [pscustomobject]@{ schemaVersion=1; host=[pscustomobject]@{NodeId=$Tailnet.NodeId;IP=$Tailnet.IP;DNS=$Tailnet.DNS;User=$user;Port=3300}; devices=@($devices) }
    Assert-AccessProfile $profile
    return $profile
}

function New-AccessPolicy($Profile) {
    Assert-AccessProfile $Profile
    $grants = @(); $tests = @()
    foreach ($device in @($Profile.devices)) {
        $ports = @(); $accept = @(); $deny = @($Profile.host.IP + ':3300')
        foreach ($pair in @(@('Codex',443), @('Ssh',22), @('RustDesk',21118))) {
            if ($device.($pair[0])) { $ports += 'tcp:' + $pair[1]; $accept += $Profile.host.IP + ':' + $pair[1] }
            else { $deny += $Profile.host.IP + ':' + $pair[1] }
        }
        if ($ports.Count) { $grants += [ordered]@{src=@($device.IP + '/32');dst=@($Profile.host.IP + '/32');ip=@($ports)} }
        $test = [ordered]@{src=$device.IP;deny=@($deny)}
        if ($accept.Count) { $test.accept = @($accept) }
        $tests += $test
    }
    [ordered]@{grants=@($grants);tests=@($tests)}
}

function Get-AuthorizedKeyText([string[]]$LegacyLines, $Profile) {
    Assert-AccessProfile $Profile
    $lines = @('# Managed by Codex Remote Access device wizard. Do not edit; use Setup.ps1.')
    $legacyIPs = @($Profile.devices | Where-Object { $_.Ssh -and $_.LegacySsh } | ForEach-Object { $_.IP } | Sort-Object -Unique)
    $legacyKeys = @($LegacyLines | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { ConvertTo-PublicKey $_ })
    if ($legacyIPs.Count) {
        foreach ($key in $legacyKeys) {
            $lines += ('from="' + ($legacyIPs -join ',') + '" ' + $key + ' codex-legacy-group')
        }
    }
    # The wizard merges partial results in ID order. Keep key rendering independent
    # of UI/profile ordering so the next update recognizes its own previous output.
    foreach ($device in @($Profile.devices | Where-Object { $_.Ssh -and -not $_.LegacySsh } | Sort-Object Id)) {
        if ($legacyIPs.Count -and (ConvertTo-PublicKey $device.PublicKey) -in $legacyKeys) { throw 'A new device must use its own key, not a legacy device key.' }
        $lines += ('from="' + $device.IP + '" ' + (ConvertTo-PublicKey $device.PublicKey) + ' codex-device=' + $device.Id)
    }
    return (($lines -join "`n") + "`n")
}

Export-ModuleMember -Function *
