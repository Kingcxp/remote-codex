[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$bundle=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $bundle 'scripts\Access-Common.psm1') -Force -DisableNameChecking
$script:checks=0
function Assert-True($Value,[string]$Message) { if(-not $Value){throw ('FAIL: '+$Message)}; $script:checks++ }
function Assert-Throws([scriptblock]$Code,[string]$Message) { $thrown=$false;try{& $Code | Out-Null}catch{$thrown=$true};Assert-True $thrown $Message }
function Copy-Value($Value) { $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('codex-onboarding-test-'+[Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixtureRoot)
try {
    foreach($file in @(Get-Item (Join-Path $bundle 'Setup.ps1'))+@(Get-Item (Join-Path $bundle 'Install.ps1'))+@(Get-ChildItem (Join-Path $bundle 'scripts') -Filter '*.ps*1')+@(Get-ChildItem (Join-Path $bundle 'clients') -Filter '*.ps1')){
        $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$t,[ref]$e)
        Assert-True ($e.Count -eq 0) ('PowerShell syntax: '+$file.Name)
        if([IO.File]::ReadAllText($file.FullName) -match '[^\x00-\x7f]'){
            $prefix=[IO.File]::ReadAllBytes($file.FullName)
            Assert-True ($prefix.Length -ge 3 -and $prefix[0] -eq 239 -and $prefix[1] -eq 187 -and $prefix[2] -eq 191) ('UTF-8 BOM for Windows PowerShell Chinese text: '+$file.Name)
        }
    }
    foreach($invalid in @('192.168.1.2','100.63.255.255','100.128.0.1','100.064.0.1','100.64.0.1/32','100.64.0.1,100.64.0.2','::1','100.64.0.1; whoami')) { Assert-Throws {Assert-TailAddress $invalid} ('reject address '+$invalid) }
    foreach($valid in @('100.64.0.0','100.127.255.255','100.100.100.10')) { Assert-True ((Assert-TailAddress $valid) -eq $valid) ('valid address '+$valid) }
    Assert-True ((@(Get-BlockedIPv4Ranges @()) -join ',') -eq '0.0.0.0-255.255.255.255') 'empty SSH set blocks everything'
    $random=[Random]::new(21)
    for($case=0;$case -lt 60;$case++){
        $allowed=@(1..($case % 9 + 1) | ForEach-Object {'100.'+$random.Next(64,128)+'.'+$random.Next(256)+'.'+$random.Next(256)})
        $ranges=@(Get-BlockedIPv4Ranges $allowed)
        $allowedNumbers=@($allowed | ForEach-Object {ConvertTo-IPv4Number $_})
        $intervals=@($ranges | ForEach-Object {$p=$_.Split('-'); ,@((ConvertTo-IPv4Number $p[0]),(ConvertTo-IPv4Number $p[1]))})
        foreach($point in @([uint64]0,[uint64]4294967295)+@($allowedNumbers)+@($allowedNumbers | ForEach-Object {$_-1;$_+1})){
            $blocked=@($intervals | Where-Object {$point -ge $_[0] -and $point -le $_[1]}).Count -gt 0
            Assert-True ($blocked -eq ($point -notin $allowedNumbers)) 'allow/block complement has no overlap or gaps'
        }
    }
    # Wire-format fixtures are public test keys, never real credentials.
    $public1='ssh-ed25519 '+[Convert]::ToBase64String([byte[]](@(0,0,0,11)+[Text.Encoding]::ASCII.GetBytes('ssh-ed25519')+@(0,0,0,32)+(1..32)))
    $public2='ssh-ed25519 '+[Convert]::ToBase64String([byte[]](@(0,0,0,11)+[Text.Encoding]::ASCII.GetBytes('ssh-ed25519')+@(0,0,0,32)+(33..64)))
    Assert-True ((ConvertTo-PublicKey ($public1+' comment')) -eq $public1) 'normalize public key without comments'
    foreach($bad in @('-----BEGIN OPENSSH PRIVATE KEY-----', ($public1+"`n"+$public2), ('from="*" '+$public1),'ssh-rsa AAAA','ssh-ed25519 AAAA')){Assert-Throws {ConvertTo-PublicKey $bad} 'reject invalid/private/multiple key input'}
    $hostData=[pscustomobject]@{NodeId='host-node';IP='100.64.0.10';DNS='windows.tailtest.ts.net';User='tester';Port=3300}
    $old=[pscustomobject]@{Id=('a'*32);NodeId='old-node';Name='Existing Linux';Platform='linux';IP='100.64.0.20';Codex=$true;Ssh=$true;RustDesk=$true;LegacySsh=$true;PublicKey='';BrowserIds=@()}
    $phone=[pscustomobject]@{Id=('b'*32);NodeId='phone-node';Name='Android';Platform='android';IP='100.64.0.30';Codex=$true;Ssh=$false;RustDesk=$true;LegacySsh=$false;PublicKey='';BrowserIds=@()}
    $new=[pscustomobject]@{Id=('c'*32);NodeId='new-node';Name='New Windows';Platform='windows';IP='100.64.0.40';Codex=$true;Ssh=$true;RustDesk=$true;LegacySsh=$false;PublicKey=$public2;BrowserIds=@()}
    $previous=[pscustomobject]@{schemaVersion=1;host=$hostData;devices=@($old,$phone)}
    $desired=Copy-Value $previous; $desired.devices+=Copy-Value $new
    Assert-AccessProfile $desired
    $policy=New-AccessPolicy $desired
    Assert-True ($policy.grants.Count -eq 3) 'adding third device retains existing grants'
    Assert-True ($policy.grants[1].ip -notcontains 'tcp:22') 'Android has no SSH grant'
    Assert-True (@($policy.tests | Where-Object {$_.deny -notcontains '100.64.0.10:3300'}).Count -eq 0) 'every client denied direct bridge port'
    $text=Get-AuthorizedKeyText @($public1) $desired
    Assert-True ($text.Contains('from="100.64.0.20" '+$public1)) 'legacy key limited to legacy source IP'
    Assert-True ($text.Contains('from="100.64.0.40" '+$public2)) 'new key bound to its own source IP'
    $public3='ssh-ed25519 '+[Convert]::ToBase64String([byte[]](@(0,0,0,11)+[Text.Encoding]::ASCII.GetBytes('ssh-ed25519')+@(0,0,0,32)+(65..96)))
    $multi=Copy-Value $desired;$extra=Copy-Value $new;$extra.Id='1'*32;$extra.NodeId='second-new';$extra.IP='100.64.0.60';$extra.PublicKey=$public3;$multi.devices+=$extra
    $reordered=Copy-Value $multi;$reordered.devices=@($reordered.devices|Sort-Object Id)
    Assert-True ((Get-AuthorizedKeyText @($public1) $multi) -ceq (Get-AuthorizedKeyText @($public1) $reordered)) 'SSH key output stays stable after profile/device reordering'
    $revoked=Copy-Value $desired;$revoked.devices=@($revoked.devices|Where-Object Id -ne $new.Id)
    $revokedText=Get-AuthorizedKeyText @($public1) $revoked
    Assert-True (-not $revokedText.Contains($public2)) 'revoke removes new key'
    Assert-True ($revokedText.Contains($public1)) 'revoke retains old key'
    $noLegacy=Copy-Value $desired;$noLegacy.devices=@($noLegacy.devices|Where-Object Id -ne $old.Id)
    Assert-True (-not (Get-AuthorizedKeyText @($public1) $noLegacy).Contains($public1)) 'last legacy client removal deactivates legacy keys'
    $sharedLegacy=Copy-Value $desired;$sharedLegacy.devices[2].PublicKey=$public1;Assert-Throws {Get-AuthorizedKeyText @($public1) $sharedLegacy} 'reject a legacy key copied to a new device'
    $duplicate=Copy-Value $desired;$duplicate.devices+=Copy-Value $new;Assert-Throws {Assert-AccessProfile $duplicate} 'reject duplicate device'
    $duplicate=Copy-Value $desired;$copy=Copy-Value $new;$copy.Id='d'*32;$copy.NodeId='other';$copy.IP='100.64.0.50';$duplicate.devices+=$copy;Assert-Throws {Assert-AccessProfile $duplicate} 'reject shared device SSH private key'
    $invalid=Copy-Value $desired;$invalid.devices[2].Name="bad`nlabel";Assert-Throws {Assert-AccessProfile $invalid} 'reject control characters in labels'
    $invalid=Copy-Value $desired;$invalid.host.User='user;whoami';Assert-Throws {Assert-AccessProfile $invalid} 'reject command-like user'
    $dataPath=Join-Path $fixtureRoot 'roundtrip.json';Write-AccessJson $dataPath $desired;Write-AccessJson $dataPath $previous
    Assert-True ((Get-Content $dataPath -Raw|ConvertFrom-Json).devices.Count -eq 2) 'atomic JSON create and replacement'
    # Load only local function definitions; do not run the interactive entry point.
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $bundle 'Setup.ps1'),[ref]$t,[ref]$e)
    foreach($definition in @($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false))) { . ([scriptblock]::Create($definition.Extent.Text)) }
    $root=$fixtureRoot
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'clients'),(Join-Path $root 'state\onboarding') -Force)
    Copy-Item -LiteralPath (Join-Path $bundle 'clients\Connect.ps1'),(Join-Path $bundle 'clients\connect.sh') -Destination (Join-Path $root 'clients')
    [IO.File]::WriteAllText((Join-Path $root 'state\secrets.dpapi'),'DO-NOT-EXPORT-CREDENTIAL')
    $receipt=[pscustomobject]@{SshApplied=$true;RustDeskApplied=$false}
    $partial=Merge-PartialProfile $previous $desired $receipt
    $newPartial=@($partial.devices|Where-Object Id -eq $new.Id)[0]
    Assert-True ($newPartial.Ssh -and -not $newPartial.RustDesk) 'partial failure records SSH success without claiming RustDesk success'
    Assert-True (@($partial.devices|Where-Object RustDesk).Count -eq 2) 'partial failure preserves existing RustDesk devices'
    $bootstrapPartial=Merge-PartialProfile $previous $desired ([pscustomobject]@{SshApplied=$false;BootstrapDeviceId=$new.Id;RustDeskApplied=$false})
    $bootDevice=@($bootstrapPartial.devices|Where-Object Id -eq $new.Id)[0]
    Assert-True ($bootDevice.Ssh -and $bootDevice.LegacySsh -and -not $bootDevice.PublicKey) 'partial initial SSH install remains tracked as imported baseline for retry'
    $empty=Copy-Value $desired;$empty.devices=@()
    $partial=Merge-PartialProfile $desired $empty ([pscustomobject]@{SshApplied=$false;RustDeskApplied=$true})
    Assert-True (@($partial.devices).Count -eq 2) 'partial revoke retains SSH permissions if SSH step failed'
    Assert-True (@($partial.devices|Where-Object RustDesk).Count -eq 0) 'partial revoke records successful RustDesk removal'
    $allGone=Merge-PartialProfile $desired $empty ([pscustomobject]@{SshApplied=$true;RustDeskApplied=$true})
    Assert-True (@($allGone.devices).Count -eq 0) 'last device revoke supports empty profile'
    $saved=Apply-Profile $previous (Copy-Value $previous)
    Assert-True ($saved -is [pscustomobject] -and $saved.devices.Count -eq 2) 'no-change apply returns only profile, not console output'
    $folder=Export-ClientGuide $desired $new
    $files=@(Get-ChildItem -LiteralPath $folder -File)
    Assert-True ($files.Count -eq 5) 'client packet has scripts, connection data and both readable guides'
    Assert-True (@($files|Where-Object { (Get-Content $_.FullName -Raw).Contains('DO-NOT-EXPORT-CREDENTIAL') }).Count -eq 0) 'client export excludes host secrets'
    Assert-True ((Get-Content (Join-Path $folder 'connection.txt') -Raw).Contains('SSHUser=tester')) 'client packet uses selected host account'
    $roundtrip=Get-Content (Join-Path $root 'state\access-devices.json') -Raw|ConvertFrom-Json
    $fakeTail=[pscustomobject]@{NodeId=$hostData.NodeId;IP=$hostData.IP;DNS=$hostData.DNS;Peers=@()}
    $loaded=Get-AccessProfile $root $fakeTail
    Assert-True ($loaded.devices.Count -eq 2) 'saved device profile reloads'
    $fakeTail.NodeId='another-host';Assert-Throws {Get-AccessProfile $root $fakeTail} 'refuse host state copied to different host'
    # Exercise the real SSH replacement/rollback function against fixture files and mocked OS cmdlets.
    $t=$null;$e=$null;$helperAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $bundle 'scripts\Update-Device-Access.ps1'),[ref]$t,[ref]$e)
    foreach($definition in @($helperAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false))) { . ([scriptblock]::Create($definition.Extent.Text)) }
    function Protect-AccessBackup([string]$Path) {} # Only fixture data; never request elevation in tests.
    function Assert-ProtectedKeyPath([string]$Path,[string]$UserSid,[bool]$AdministratorFile) { Assert-True ($Path.StartsWith($fixtureRoot)) 'protected key target stays inside test fixture' }
    function Assert-SshConfigValid([string]$ConfigPath) { Assert-True (Test-Path -LiteralPath $ConfigPath) 'sshd validates fixture config' }
    $script:mockRules=@{
        'CodexPrivateSSH-Allow'=[pscustomobject]@{Name='CodexPrivateSSH-Allow';Enabled='True';Remote=@($old.IP);Local=@($hostData.IP)}
        'CodexPrivateSSH-BlockOthers'=[pscustomobject]@{Name='CodexPrivateSSH-BlockOthers';Enabled='True';Remote=@(Get-BlockedIPv4Ranges @($old.IP));Local=@($hostData.IP)}
    }
    function Get-NetFirewallRule([string]$Name) { return $script:mockRules[$Name] }
    function Get-NetFirewallAddressFilter {
        param([Parameter(ValueFromPipeline=$true)]$InputObject)
        process { [pscustomobject]@{LocalAddress=@($InputObject.Local);RemoteAddress=@($InputObject.Remote)} }
    }
    $script:failFirewallOnce=$false
    $script:firewallWrites=0
    function Set-NetFirewallRule {
        param([string]$Name,[string[]]$RemoteAddress,[string]$Enabled)
        $script:firewallWrites++
        if($script:failFirewallOnce -and $Name -eq 'CodexPrivateSSH-BlockOthers' -and $RemoteAddress.Count -eq 3){$script:failFirewallOnce=$false;throw 'Simulated firewall commit failure'}
        if($PSBoundParameters.ContainsKey('RemoteAddress')){$script:mockRules[$Name].Remote=@($RemoteAddress)}
        if($PSBoundParameters.ContainsKey('Enabled')){$script:mockRules[$Name].Enabled=$Enabled}
    }
    $fakeUserDir=Join-Path $fixtureRoot 'fake-user'
    function Get-LocalUser([string]$Name) { [pscustomobject]@{SID=[pscustomobject]@{Value='S-1-5-21-test'}} }
    function Get-ItemProperty([string]$LiteralPath) { [pscustomobject]@{ProfileImagePath=$fakeUserDir} }
    function Restart-Service { throw 'Tests must not restart any service' }
    $savedProgramData=$env:ProgramData
    try {
        $env:ProgramData=Join-Path $fixtureRoot 'fake-programdata'
        $sshDir=Join-Path $env:ProgramData 'ssh';[void](New-Item -ItemType Directory -Path $sshDir -Force)
        $keyFile=Join-Path $sshDir 'authorized_keys_codex_tester'
        [IO.File]::WriteAllText($keyFile,$public1+"`n")
        [IO.File]::WriteAllText((Join-Path $sshDir 'sshd_config'),('# Managed by Codex Remote Access.'+"`nAllowUsers tester`nAuthorizedKeysFile `""+$keyFile.Replace('\','/')+"`"`n"))
        $plan=[pscustomobject]@{Previous=$previous;Desired=$desired}
        $tailnet=[pscustomobject]@{IP=$hostData.IP}
        $sshIPs=@($desired.devices|Where-Object Ssh|ForEach-Object IP)
        $receipt=[ordered]@{BackupDirectory=''}
        $planPathFull=Join-Path $fixtureRoot 'access-plan.json'
        $originalKeys=Get-Content $keyFile -Raw
        $script:failFirewallOnce=$true
        Assert-Throws {Update-SshDeviceAccess} 'injected firewall failure triggers rollback'
        Assert-True ((Get-Content $keyFile -Raw) -ceq $originalKeys) 'rollback restores original authorized keys'
        Assert-True (($script:mockRules['CodexPrivateSSH-Allow'].Remote -join ',') -eq $old.IP) 'rollback restores original allowed IP'
        Assert-True ($script:mockRules['CodexPrivateSSH-BlockOthers'].Remote.Count -eq 2) 'rollback restores original blocking ranges'
        Update-SshDeviceAccess
        Assert-True ((Get-Content $keyFile -Raw).Contains('from="100.64.0.40" '+$public2)) 'successful multi-device update writes new bounded key'
        Assert-True ($script:mockRules['CodexPrivateSSH-Allow'].Remote.Count -eq 2) 'multi-device update allows both SSH clients'
        Assert-True ($script:mockRules['CodexPrivateSSH-BlockOthers'].Remote.Count -eq 3) 'multi-device update fixes old block rule as well as allow rule'
        Assert-True (Test-Path -LiteralPath (Join-Path $env:ProgramData 'CodexPrivateSSH\devices\legacy-keys.json')) 'legacy key baseline stored for later revocation'
        $committed=Get-Content $keyFile -Raw
        [IO.File]::AppendAllText($keyFile,"# External manual change`n")
        $plan.Previous=$desired;$plan.Desired=$revoked;$sshIPs=@($revoked.devices|Where-Object Ssh|ForEach-Object IP)
        $beforeWrites=$script:firewallWrites
        Assert-Throws {Update-SshDeviceAccess} 'refuses to overwrite externally modified keys'
        Assert-True ($script:firewallWrites -eq $beforeWrites) 'external modification refusal leaves firewall unchanged'
        [IO.File]::WriteAllText($keyFile,$committed)
        $plan.Previous=$desired;$plan.Desired=$multi;$sshIPs=@($multi.devices|Where-Object Ssh|ForEach-Object IP)
        Update-SshDeviceAccess
        Assert-True ((Get-Content $keyFile -Raw).Contains($public3)) 'adding a further SSH device succeeds'
        $mergedMulti=Merge-PartialProfile $desired $multi ([pscustomobject]@{SshApplied=$true;RustDeskApplied=$true})
        $plan.Previous=$mergedMulti;$plan.Desired=$desired;$sshIPs=@($desired.devices|Where-Object Ssh|ForEach-Object IP)
        Update-SshDeviceAccess
        Assert-True (-not (Get-Content $keyFile -Raw).Contains($public3)) 'subsequent update accepts saved ID ordering and removes only the selected key'
        $plan.Previous=$desired;$plan.Desired=$revoked;$sshIPs=@($revoked.devices|Where-Object Ssh|ForEach-Object IP)
        Update-SshDeviceAccess
        Assert-True (-not (Get-Content $keyFile -Raw).Contains($public2)) 'real revoke update removes only new key'
        Assert-True ((Get-Content $keyFile -Raw).Contains($public1)) 'real revoke update preserves legacy key'
        $lastRemoved=Copy-Value $revoked;$lastRemoved.devices=@($lastRemoved.devices|Where-Object {-not $_.Ssh})
        $plan.Previous=$revoked;$plan.Desired=$lastRemoved;$sshIPs=@()
        Update-SshDeviceAccess
        Assert-True ($script:mockRules['CodexPrivateSSH-Allow'].Enabled -eq 'False') 'last SSH client removal disables allow rule'
        Assert-True (($script:mockRules['CodexPrivateSSH-BlockOthers'].Remote -join ',') -eq '0.0.0.0-255.255.255.255') 'last SSH client removal blocks all sources'
        Assert-True (-not (Get-Content $keyFile -Raw).Contains($public1)) 'last legacy client removal deactivates old public key'
    } finally { $env:ProgramData=$savedProgramData }
    $connectionClient=Join-Path $bundle 'clients\Connect.ps1'
    Assert-Throws {& $connectionClient -HostName 'bad;whoami' -HostIP '100.64.0.1' -SSHUser 'user' -Action Check} 'client rejects unsafe host before any networking'
    Assert-Throws {& (Join-Path $bundle 'scripts\Configure-RustDesk.ps1') -AllowedClientIPs @()} 'empty RustDesk whitelist rejected before any configuration'
    [void](New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force)
    Copy-Item -LiteralPath (Join-Path $bundle 'scripts\Update-Device-Access.ps1'),(Join-Path $bundle 'scripts\Access-Common.psm1') -Destination (Join-Path $root 'scripts')
    $previewPlan=Join-Path $root 'state\onboarding\preview-plan.json'
    Write-AccessJson $previewPlan ([ordered]@{version=1;Previous=$previous;Desired=$desired;ConfigureShell=$false;RustDeskSourcePath=''})
    $preview=& (Join-Path $root 'scripts\Update-Device-Access.ps1') -PlanPath $previewPlan | ConvertFrom-Json
    Assert-True ($preview.PreviewOnly -and @($preview.SshClients).Count -eq 2 -and @($preview.RustDeskClients).Count -eq 3) 'administrator helper preview supports full multi-device plan without applying it'
    Assert-Throws {& (Join-Path $root 'scripts\Update-Device-Access.ps1') -PlanPath $previewPlan -PlanSha256 ('0'*64)} 'changed plan hash is refused'
    Assert-Throws {& (Join-Path $root 'scripts\Update-Device-Access.ps1') -PlanPath (Join-Path $root 'roundtrip.json')} 'plan outside private onboarding directory is refused'
    # Walk through the actual Add-Device UI with fixture Tailscale and scripted answers.
    Save-Profile $previous
    $script:wizardTail=[pscustomobject]@{Executable='test-only';NodeId=$hostData.NodeId;IP=$hostData.IP;DNS=$hostData.DNS;Peers=@([pscustomobject]@{ID='third-phone-node';HostName='Third Phone';OS='android';TailscaleIPs=@('100.64.0.50');Online=$true})}
    function Get-AccessTailnet { return $script:wizardTail }
    function Assert-PrivateServe($Tailnet) { Assert-True ($Tailnet.Executable -eq 'test-only') 'wizard private Serve check uses fixture' }
    $script:answers=New-Object 'Collections.Generic.Queue[string]'
    foreach($answer in @('','1','My third phone','y','n','n','n','n')) { $script:answers.Enqueue($answer) }
    function Read-Host([string]$Prompt) { if(-not $script:answers.Count){throw ('Unexpected prompt: '+$Prompt)}; return $script:answers.Dequeue() }
    Add-Device
    $onboarded=Get-Content (Join-Path $root 'state\access-devices.json') -Raw|ConvertFrom-Json
    Assert-True (@($onboarded.devices).Count -eq 3) 'interactive Add-Device retains old devices and saves third phone'
    Assert-True (@($onboarded.devices|Where-Object { $_.IP -eq '100.64.0.50' -and $_.Codex -and -not $_.Ssh -and -not $_.RustDesk }).Count -eq 1) 'interactive Codex-only selection does not add SSH or RustDesk permissions'
    Assert-True (@($onboarded.devices|Where-Object Ssh).Count -eq 1 -and @($onboarded.devices|Where-Object RustDesk).Count -eq 2) 'interactive onboarding preserves existing system feature permissions'
    Assert-True ($script:answers.Count -eq 0) 'all expected wizard prompts consumed'
    $script:fixtureRuntime=Join-Path $root 'runtime\local-runtime.mjs'
    function Get-CimInstance { param($ClassName,$Filter); [pscustomobject]@{CommandLine=('node.exe "'+$script:fixtureRuntime+'"')} }
    function Invoke-RestMethod { param($Uri,$TimeoutSec); [pscustomobject]@{ok=$true} }
    Assert-True (-not (Test-BridgeReady)) 'healthy port without this bundle process record is not treated as its bridge'
    Write-AccessJson (Join-Path $root 'state\process.json') ([ordered]@{pid=1234;port=3300})
    Assert-True (Test-BridgeReady) 'healthy bridge owned by this bundle is accepted'
    $script:fixtureRuntime='C:\another-installation\runtime\local-runtime.mjs'
    Assert-True (-not (Test-BridgeReady)) 'another installation cannot create pairing against the wrong registry'
    [pscustomobject]@{Passed=$script:checks;PowerShell=$PSVersionTable.PSVersion.ToString();ChangesToRealServices=$false;ChangesToRealDevices=$false} | ConvertTo-Json -Compress
} finally {
    $resolved=[IO.Path]::GetFullPath($fixtureRoot)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'codex-onboarding-test-*') { throw 'Unexpected cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
