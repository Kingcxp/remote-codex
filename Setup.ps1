[CmdletBinding()]
param(
    [ValidateSet('Menu','Check','PrepareHost','AddDevice','Devices','Pair','Revoke','Policy','Start','Client','ExportClients')][string]$Action='Menu'
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
foreach ($template in @(
    @{ Source='docs\BUILD-INFO.template.json'; Target='docs\BUILD-INFO.json' },
    @{ Source='docs\VALIDATION.template.json'; Target='docs\VALIDATION.json' }
)) {
    $targetPath = Join-Path $root $template.Target
    if (-not (Test-Path -LiteralPath $targetPath)) {
        Copy-Item -LiteralPath (Join-Path $root $template.Source) -Destination $targetPath
    }
}
Import-Module (Join-Path $root 'scripts\Access-Common.psm1') -Force -DisableNameChecking

function Confirm-Step([string]$Prompt, [switch]$DefaultYes) {
    $answer = (Read-Host ($Prompt + $(if($DefaultYes){' [Y/n]'}else{' [y/N]'}))).Trim()
    if (-not $answer) { return [bool]$DefaultYes }
    return $answer -match '^(y|yes|是|确认)$'
}
function Protect-OnboardingState {
    $state = Join-Path $root 'state'
    if (-not (Test-Path -LiteralPath $state)) {
        [void](New-Item -ItemType Directory -Path $state)
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true,$false)
        $acl.SetOwner($sid)
        foreach ($allowed in @($sid.Value,'S-1-5-18')) {
            [void]$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($allowed),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        }
        Set-Acl -LiteralPath $state -AclObject $acl
    }
    [void](New-Item -ItemType Directory -Path (Join-Path $state 'onboarding') -Force)
}
function Invoke-WithDeviceLock([scriptblock]$Work) {
    Protect-OnboardingState
    $lock = $null
    try {
        try { $lock = [IO.File]::Open((Join-Path $root 'state\onboarding\wizard.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { throw '另一个设备配置向导正在操作。请先退出那个向导；不要删除它的锁文件。' }
        & $Work
    } finally { if ($lock) { $lock.Dispose() } }
}
function Get-Browsers {
    if (-not (Test-Path -LiteralPath (Join-Path $root 'state\devices.json'))) { return }
    $raw = & node.exe (Join-Path $root 'runtime\access-devices.mjs') list (Join-Path $root 'state\devices.json')
    if ($LASTEXITCODE -ne 0) { throw '无法读取 Codex 浏览器配对。请检查 Node.js 与完整的安装包。' }
    return ($raw | ConvertFrom-Json)
}
function Save-Profile($Profile) {
    Assert-AccessProfile $Profile
    $old = Join-Path $root 'state\access-devices.json'
    if (Test-Path -LiteralPath $old) {
        $history = Join-Path $root 'state\onboarding\profile-history'
        [void](New-Item -ItemType Directory -Path $history -Force)
        Copy-Item -LiteralPath $old -Destination (Join-Path $history ([Guid]::NewGuid().ToString('N') + '.json'))
    }
    Write-AccessJson $old $Profile
    Write-AccessJson (Join-Path $root 'state\onboarding\tailnet-policy.json') (New-AccessPolicy $Profile)
}
function Show-ConnectionCheck {
    Write-Host "`n只读检查；此操作不会重启服务或更改配置。" -ForegroundColor Cyan
    $checks = @()
    try {
        $node = Get-Command node.exe -ErrorAction Stop
        $version = (& $node.Source -p 'process.versions.node').Trim()
        if ($LASTEXITCODE -ne 0 -or [version]$version -lt [version]'22.12.0') { throw '需要 Node.js 22.12 或更新版本。' }
        $checks += [pscustomobject]@{项目='Node.js';结果=$version}
    } catch { $checks += [pscustomobject]@{项目='Node.js';结果=$_.Exception.Message} }
    try {
        $tail = Get-AccessTailnet
        Assert-PrivateServe $tail
        $checks += [pscustomobject]@{项目='Tailscale';结果=($tail.IP + ' / ' + $tail.DNS + '；未开启 Funnel')}
        $profile = Get-AccessProfile $root $tail
        $checks += [pscustomobject]@{项目='设备记录';结果=(@($profile.devices).Count.ToString() + ' 台；首次会保留已有 SSH / RustDesk 白名单')}
    } catch { $checks += [pscustomobject]@{项目='Tailscale / 设备记录';结果=$_.Exception.Message} }
    try {
        if (-not (Test-BridgeReady)) { throw '此目录的桥接未运行。' }
        $health = Invoke-RestMethod 'http://127.0.0.1:3300/health' -TimeoutSec 3
        if (-not $health.ok) { throw '桥接未就绪。' }
        $checks += [pscustomobject]@{项目='Codex 桥接';结果='本机 /health 正常；可继续检查外部入口'}
    } catch { $checks += [pscustomobject]@{项目='Codex 桥接';结果='未就绪：先打开桌面 App，再选择「启动桥接」'} }
    if ($tail) {
        try {
            $health = Invoke-RestMethod ("https://$($tail.DNS)/health") -TimeoutSec 8
            if (-not $health.ok) { throw '入口未就绪。' }
            $checks += [pscustomobject]@{项目='Codex 私网 HTTPS';结果='证书与入口检查通过；新设备仍需单独验证'}
        } catch { $checks += [pscustomobject]@{项目='Codex 私网 HTTPS';结果='未通过：检查桥接、Serve / HTTPS 授权与 tailnet 规则'} }
    }
    foreach ($serviceName in @('sshd','RustDesk')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $checks += [pscustomobject]@{项目=$serviceName;结果=$(if($service){[string]$service.Status}else{'未安装（可选功能）'})}
    }
    $checks | Format-Table -AutoSize -Wrap
    Write-Host '完整教程：docs\INSTALL.zh-CN.md。连接失败请保留具体报错；检查不等于所有客户端已经登录成功。'
}
function Test-BridgeReady {
    try {
        $recordPath=Join-Path $root 'state\process.json'
        if (-not (Test-Path -LiteralPath $recordPath)) { return $false }
        $record=Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        if ([int]$record.pid -le 0 -or [int]$record.port -ne 3300) { return $false }
        $process=Get-CimInstance Win32_Process -Filter ('ProcessId = ' + [int]$record.pid)
        $runtime=Join-Path $root 'runtime\local-runtime.mjs'
        if (-not $process -or -not $process.CommandLine -or $process.CommandLine.IndexOf($runtime,[StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        return [bool](Invoke-RestMethod 'http://127.0.0.1:3300/health' -TimeoutSec 2).ok
    } catch { return $false }
}
function Prepare-Host {
    Write-Host "`n这台 Windows 是运行 Codex 桌面 App 的主机。新电脑只作客户端时，请选主菜单 9。" -ForegroundColor Cyan
    Write-Host '主机继续使用桌面 App 中现有的中转 API 配置；不需要把 API 密钥复制到手机或新电脑。'
    try { $null = Get-TailscaleExecutable } catch {
        Write-Host '先安装官方 Tailscale。安装会请求管理员权限，因为需要虚拟网卡与系统服务。'
        if (Confirm-Step '打开官方下载页？' -DefaultYes) { Start-Process 'https://tailscale.com/download/windows' }
        $null = Read-Host '完成安装并在托盘 Tailscale 登录私人账户后，按 Enter 继续'
    }
    $tail = Get-AccessTailnet
    Assert-PrivateServe $tail
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Host '需要 Node.js 22.12 或更新版本。安装 LTS 版本；安装器可能请求管理员权限。'
        if (Confirm-Step '打开 Node.js 官方下载页？' -DefaultYes) { Start-Process 'https://nodejs.org/en/download' }
        $null = Read-Host '安装结束后按 Enter 继续'
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
        $node = Get-Command node.exe -ErrorAction Stop
    }
    $nodeVersion = (& $node.Source -p 'process.versions.node').Trim()
    if ($LASTEXITCODE -ne 0 -or [version]$nodeVersion -lt [version]'22.12.0') { throw 'Node.js 版本过旧，请安装 22.12 或更新版本后重新打开 PowerShell。' }
    Write-Host '请先打开 Windows Codex 桌面 App，确认本机能够发送消息。保持它登录当前 Windows 用户。'
    if (-not (Test-BridgeReady)) {
        try { $occupied=Invoke-RestMethod 'http://127.0.0.1:3300/health' -TimeoutSec 2 } catch { $occupied=$null }
        if ($occupied -and $occupied.ok) { throw '3300 上有另一份桥接正在运行。请使用它所在目录的 Setup.ps1；不要在另一个解压目录生成配对。要迁移目录，请先在原前台窗口停止后再迁移。' }
        Protect-OnboardingState
        $settingsPath = Join-Path $root 'state\settings.json'
        if (-not (Test-Path -LiteralPath $settingsPath)) {
            $workspace = (Read-Host '填写允许新建 Codex 任务的已有工作文件夹完整路径').Trim().Trim('"')
            if (-not (Test-Path -LiteralPath $workspace -PathType Container)) { throw '请选择一个已经存在的工作文件夹。向导不会创建或修改其中的项目。' }
            $settings = [ordered]@{port=3300;deviceId=('windows-' + [Guid]::NewGuid().ToString('N'));deviceLabel=($env:COMPUTERNAME + ' / Codex Desktop');allowedRoots=@((Resolve-Path -LiteralPath $workspace).Path);codexBin=''}
            Write-AccessJson $settingsPath $settings
        }
        Write-Host '桥接必须保持一个可见的 PowerShell 窗口运行；关闭窗口后远程 Codex 会离线。'
        if (-not (Confirm-Step '现在打开一个前台 PowerShell 窗口运行 Start.ps1？' -DefaultYes)) { throw '请自行运行 Start.ps1，看到 Ready 后再来继续设置。' }
        $startPath = (Join-Path $root 'Start.ps1').Replace("'","''")
        $command = "& '$startPath'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        # A visible, user-requested interactive terminal; no hidden bridge or scheduled task.
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoLogo','-NoProfile','-NoExit','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Normal
        $null = Read-Host '等新窗口出现 [bridge] Ready 后，回到这里按 Enter（如有错误请先处理，不要关掉新窗口）'
        if (-not (Test-BridgeReady)) { throw '桥接尚未就绪，请查看启动窗口的报错。' }
    }
    & (Join-Path $root 'scripts\Configure-Private-Access.ps1') -ApplyServe
    $health = Invoke-RestMethod ("https://$($tail.DNS)/health") -TimeoutSec 10
    if (-not $health.ok) { throw '私网 HTTPS 尚未就绪。按 Tailscale 提供的链接启用 HTTPS，再选择「准备主机」重试。' }
    Write-Host ("主机入口已检查：https://$($tail.DNS)/。下一步选择「添加设备」。") -ForegroundColor Green
}
function Show-Policy($Profile) {
    Protect-OnboardingState
    $path = Join-Path $root 'state\onboarding\tailnet-policy.json'
    Write-AccessJson $path (New-AccessPolicy $Profile)
    Write-Host "`n访问规则文件：$path" -ForegroundColor Cyan
    Write-Host '它只是一份本机规则草稿，尚未上传或应用。'
    Write-Host '打开 https://login.tailscale.com/admin/acls。专用于这些设备的新 tailnet，可用这份 JSON 替换初始 allow-all。'
    Write-Host '已有 PVE 或其他服务时，把 grants / tests 合并进现有规则，保留其他服务规则；删除仍覆盖本主机这些端口的广泛放行规则。'
    Write-Host '单纯追加到 allow-all 后面不能限制访问；Tailscale 的放行规则会叠加。保存时运行页面自带的测试。'
    Write-Host '向导只开放所选功能：Codex HTTPS 443、SSH 22、RustDesk TCP 21118；桥接 3300 不直接对外开放。'
    if (Confirm-Step '现在用记事本打开草稿，并打开 Tailscale 访问控制页面？') {
        Start-Process notepad.exe -ArgumentList ('"' + $path + '"')
        Start-Process 'https://login.tailscale.com/admin/acls'
        $null = Read-Host '在管理页面保存合并后的规则并通过测试后，按 Enter 继续；如暂不操作，也可按 Enter 返回后稍后处理'
    }
}
function Merge-PartialProfile($Previous,$Desired,$Receipt) {
    $merged = $Desired | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $merged.devices = @()
    $ids = @(@($Previous.devices | ForEach-Object Id) + @($Desired.devices | ForEach-Object Id) | Sort-Object -Unique)
    foreach ($id in $ids) {
        $old = @($Previous.devices | Where-Object Id -eq $id) | Select-Object -First 1
        $new = @($Desired.devices | Where-Object Id -eq $id) | Select-Object -First 1
        $item = $(if($new){$new}else{$old}) | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $item.Codex = [bool]($new -and $new.Codex)
        $sshSource = if ($Receipt.SshApplied) { $new } else { $old }
        $item.Ssh = [bool]($sshSource -and $sshSource.Ssh)
        $item.LegacySsh = [bool]($sshSource -and $sshSource.LegacySsh)
        $item.PublicKey = if ($sshSource -and $sshSource.Ssh) { $sshSource.PublicKey } else { '' }
        if (-not $Receipt.SshApplied -and $Receipt.PSObject.Properties['BootstrapDeviceId'] -and $Receipt.BootstrapDeviceId -eq $id) { $item.Ssh=$true; $item.LegacySsh=$true; $item.PublicKey='' }
        $rustSource = if ($Receipt.RustDeskApplied) { $new } else { $old }
        $item.RustDesk = [bool]($rustSource -and $rustSource.RustDesk)
        if ($item.Codex -or $item.Ssh -or $item.RustDesk) { $merged.devices += $item }
    }
    Assert-AccessProfile $merged
    return $merged
}
function Apply-Profile($Previous,$Desired,[string]$RustDeskSource='') {
    Assert-AccessProfile $Desired
    $oldSsh = @($Previous.devices | Where-Object Ssh | Select-Object Id,IP,PublicKey,LegacySsh | Sort-Object Id) | ConvertTo-Json -Depth 8 -Compress
    $newSsh = @($Desired.devices | Where-Object Ssh | Select-Object Id,IP,PublicKey,LegacySsh | Sort-Object Id) | ConvertTo-Json -Depth 8 -Compress
    $oldRust = @($Previous.devices | Where-Object RustDesk | ForEach-Object IP | Sort-Object) -join ','
    $newRust = @($Desired.devices | Where-Object RustDesk | ForEach-Object IP | Sort-Object) -join ','
    if ($oldSsh -eq $newSsh -and $oldRust -eq $newRust) { Save-Profile $Desired; return $Desired }
    $planPath = Join-Path $root ('state\onboarding\access-plan-' + [Guid]::NewGuid().ToString('N') + '.json')
    $firstSsh = -not (Get-NetFirewallRule -Name 'CodexPrivateSSH-Allow' -ErrorAction SilentlyContinue) -and @($Desired.devices | Where-Object Ssh).Count -gt 0
    Write-AccessJson $planPath ([ordered]@{version=1;Previous=$Previous;Desired=$Desired;RustDeskSourcePath=$RustDeskSource;ConfigureShell=$firstSsh})
    Write-Host "`n下面是准备应用的系统设置：" -ForegroundColor Cyan
    & (Join-Path $root 'scripts\Update-Device-Access.ps1') -PlanPath $planPath | Out-Host
    Write-Host '这一步需要管理员权限：要写入 SSH 受保护的公钥文件、修改防火墙，或配置 RustDesk 系统服务。'
    Write-Host '修改已有 SSH 白名单不重启 sshd，不改当前 PowerShell、转发规则或已有会话。首次安装 SSH 可能要下载 Windows 可选组件，耗时取决于 Windows Update。'
    if ($firstSsh) { Write-Host '首次 SSH 设置还会安装已固定校验值的独立 PowerShell 7.6.9，并用它作为 SSH 默认终端；不配置 sudo。' }
    if (-not (Confirm-Step '确认按上面的名单应用？')) { throw '已取消系统设置；设备权限记录没有改动。' }
    $sha = (Get-FileHash -LiteralPath $planPath).Hash
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        try { & (Join-Path $root 'scripts\Update-Device-Access.ps1') -PlanPath $planPath -PlanSha256 $sha -Apply | Out-Host } catch { Write-Warning $_.Exception.Message }
    } elseif ($env:SSH_CONNECTION) {
        Write-Host '当前 SSH 会话没有管理员令牌，不能在 SSH 中确认 Windows UAC。请经已授权的 RustDesk 打开管理员 PowerShell，运行下面的命令。'
        Write-Host ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'scripts\Update-Device-Access.ps1') + '" -PlanPath "' + $planPath + '" -PlanSha256 "' + $sha + '" -Apply') -ForegroundColor Cyan
        $null = Read-Host '在管理员窗口完成上述命令后，回到此 SSH 窗口按 Enter 检查结果'
    } else {
        $helperLiteral = (Join-Path $root 'scripts\Update-Device-Access.ps1').Replace("'","''")
        $planLiteral = $planPath.Replace("'","''")
        $command = "try { & '$helperLiteral' -PlanPath '$planLiteral' -PlanSha256 '$sha' -Apply; exit 0 } catch { Write-Host `$_.Exception.Message -ForegroundColor Red; exit 1 }"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        try {
            $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -PassThru -WindowStyle Normal
            Write-Host '请在弹出的 UAC 窗口允许本次操作。系统设置窗口关闭后，向导会检查结果。'
            while (-not $process.WaitForExit(1000)) { Write-Progress -Activity '等待管理员窗口完成设置' -Status '请查看该窗口；不要再次启动相同安装。' }
            Write-Progress -Activity '等待管理员窗口完成设置' -Completed
        } catch { throw ('提权未完成；请用同一个 Windows 账户确认 UAC，不能输入另一个账户的凭据。原因：' + $_.Exception.Message) }
    }
    $receiptPath = $planPath + '.result.json'
    if (-not (Test-Path -LiteralPath $receiptPath)) { throw ("管理员步骤没有返回结果，不能确认权限是否已修改。保留此计划并检查：$planPath") }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.PlanSha256 -ine $sha) { throw '结果与本次计划不匹配，停止。' }
    $actual = Merge-PartialProfile $Previous $Desired $receipt
    Save-Profile $actual
    if (-not $receipt.Success) { throw ("设置未全部完成。已保存实际完成的步骤；重新添加同一设备可重试。错误：$($receipt.Error)。结果：$receiptPath") }
    return $actual
}
function Export-ClientGuide($Profile,$Device) {
    $folder = Join-Path $root ('state\onboarding\clients\' + $Device.IP + '-' + $Device.Id.Substring(0,8))
    [void](New-Item -ItemType Directory -Path $folder -Force)
    foreach ($file in @('Connect.ps1','connect.sh')) { Copy-Item -LiteralPath (Join-Path $root ('clients\' + $file)) -Destination (Join-Path $folder $file) -Force }
    $fingerprint = Get-AccessHostFingerprint $root
    $connection = "HostName=$($Profile.host.DNS)`nHostIP=$($Profile.host.IP)`nSSHUser=$($Profile.host.User)`nFingerprint=$fingerprint`n"
    [IO.File]::WriteAllText((Join-Path $folder 'connection.txt'),$connection,[Text.UTF8Encoding]::new($false))
    $url = 'https://' + $Profile.host.DNS + '/'
    $guide = @"
# $($Device.Name) 连接指南

这是客户端连接包。可以复制整个文件夹到该设备；不需要复制 Windows 主机的完整服务目录。
包含主机地址、用户名和公开指纹，不含 API 密钥、密码、SSH 私钥或配对凭据。

## 每台新设备先做

1. 安装 Tailscale（https://tailscale.com/download），登录主机所属的同一个私人 tailnet，并开启连接。
2. 本设备在 Tailscale 中应为 $($Device.IP)。重新安装后 IP / 节点变了，需要在主机向导重新添加，不能沿用旧授权。
3. Windows 主机须保持开机、联网。Codex 还需要桌面 App 和前台 Start.ps1 窗口运行。

## Windows 客户端

打开普通 PowerShell，cd 到此文件夹后执行：

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Connect.ps1

按菜单准备、检查、打开 Codex、SSH 或 RustDesk。只有安装系统组件会请求管理员权限。

## Arch / NixOS / 其他 Linux 客户端

在此文件夹打开终端：

    bash ./connect.sh

选择 1 查看对应发行版准备步骤，2 检查，3 生成 / 显示本设备公钥，4 Codex，5 SSH，6 RustDesk。
只有公钥需要交给主机添加。每台设备各自生成密钥；私钥与口令不外传。

## Android

1. Tailscale App 登录同一 tailnet，允许 VPN 并连接；不要同时开启冲突的其他 VPN。
2. 用 Chrome 打开固定地址：$url
3. 在主机 Setup.ps1 选择「生成配对链接」，在 10 分钟内用这台设备的 Chrome 打开单次链接。
4. 确认看到已有对话后，Chrome 菜单 → 安装应用 / 添加到主屏幕。以后直接点击图标。
5. RustDesk 从 https://rustdesk.com/ 的官方下载入口安装 Android App。在「远程设备 ID」输入 $($Profile.host.IP):21118，连接后输入主机固定密码。

## SSH 与 VS Code

Windows 登录用户：$($Profile.host.User)。目标：$($Profile.host.IP):22。
主机 Ed25519 指纹：$(if($fingerprint){$fingerprint}else{'尚未导出；在主机管理员窗口使用 ssh-keygen -lf C:\ProgramData\ssh\ssh_host_ed25519_key.pub 核对。'})
首次连接核对一致后才输入 yes，不要使用 StrictHostKeyChecking=no。
客户端菜单 3 会生成独立 ssh-config，不修改已有 ~/.ssh/config。
VS Code 安装 Remote - SSH 扩展，在 Remote.SSH: Config File 中选此文件夹内的 ssh-config，再连接 codex-win。
不想改变 VS Code 的全局选择时，可将这个 Host 块手动合并进现有 SSH 配置，避免重名。

## RustDesk 与离线状态

RustDesk 目标：$($Profile.host.IP):21118。密码由主机用户在 RustDesk → 设置 → 安全中私下设置，不在此文件里。
本设备所选权限：Codex=$($Device.Codex)，SSH=$($Device.Ssh)，RustDesk=$($Device.RustDesk)。未开放的功能不能使用。
Codex 页面打不开，先保持手机 Tailscale 已连接，再运行客户端菜单 2；检查主机前台窗口、HTTPS 和 tailnet 规则。
主机关机 / 睡眠时无法连接。RustDesk / SSH 由各自系统服务提供；它们不要求 Codex 桥接窗口运行。
设备丢失：主机 Setup.ps1 → 撤销设备；同时在 Tailscale 管理页移除节点；如设备保存过 RustDesk 密码，还要在主机更换固定密码。
"@
    [IO.File]::WriteAllText((Join-Path $folder 'START-HERE.md'),$guide,[Text.UTF8Encoding]::new($true))
    $title = [Net.WebUtility]::HtmlEncode($Device.Name)
    $body = [Net.WebUtility]::HtmlEncode($guide)
    $html = "<!doctype html><html lang='zh-CN'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>$title 连接指南</title><style>body{font:16px/1.7 system-ui;max-width:880px;margin:24px auto;padding:0 20px;color:#172b3a}pre{white-space:pre-wrap;overflow-wrap:anywhere}a{color:#075cbe}</style><h1>$title</h1><p><a href='$url'>打开 Codex 固定入口</a> · <a href='https://tailscale.com/download'>安装 Tailscale</a> · <a href='https://rustdesk.com/'>安装 RustDesk</a></p><pre>$body</pre></html>"
    [IO.File]::WriteAllText((Join-Path $folder 'START-HERE.html'),$html,[Text.UTF8Encoding]::new($false))
    Write-Host "`n该设备的连接包：$folder" -ForegroundColor Cyan
    Write-Host '只复制此文件夹到新设备。手机可以直接阅读 START-HERE.html；Windows / Linux 运行各自客户端脚本。'
    return $folder
}
function Pair-Browser($Profile,$Device) {
    if (-not (Test-BridgeReady)) { throw '先选择「准备主机 / 私网入口」，保持前台桥接运行，再生成配对链接。' }
    $before = @(Get-Browsers)
    & (Join-Path $root 'scripts\Manage-Remote.ps1') -Action Pair
    Write-Host '配对链接 10 分钟有效，只能使用一次；它相当于登录凭据，不要放进共享连接包或公开聊天。'
    Write-Host '请在新设备已连接 Tailscale 的浏览器中打开链接。Android 使用 Chrome，成功后安装到主屏幕。'
    if ($Device -and (Confirm-Step '这台新设备现在已经看到原有对话了吗？')) {
        $after = @(Get-Browsers)
        $new = @($after | Where-Object { $_.id -notin @($before.id) })
        $selected = $null
        if ($new.Count -eq 1) {
            Write-Host ('检测到一个新浏览器：' + $new[0].label)
            if (Confirm-Step '确认这是刚才这台设备的浏览器？' -DefaultYes) { $selected = $new[0] }
        } elseif ($new.Count -gt 1) {
            for ($i=0;$i -lt $new.Count;$i++) { Write-Host ("$($i+1). " + $new[$i].label) }
            $answer = Read-Host '本次出现多个浏览器；输入属于这台设备的序号，留空不绑定'
            $n=0; if ([int]::TryParse($answer,[ref]$n) -and $n -ge 1 -and $n -le $new.Count) { $selected = $new[$n-1] }
        }
        if ($selected) { $Device.BrowserIds = @(@($Device.BrowserIds) + @($selected.id) | Sort-Object -Unique); Save-Profile $Profile; Write-Host '浏览器已与设备记录关联，之后撤销设备时会撤销此配对。' }
        else { Write-Host '没有自动关联浏览器；已存在的配对仍可用。撤销设备时可从浏览器列表手动选择。' }
    }
}
function Select-ProfileDevice($Profile,[string]$Prompt) {
    if (-not @($Profile.devices).Count) { throw '当前没有已记录的设备。请先添加设备。' }
    for ($i=0;$i -lt @($Profile.devices).Count;$i++) {
        $d=$Profile.devices[$i]
        Write-Host ("$($i+1). $($d.Name) [$($d.Platform)] $($d.IP) — Codex:$($d.Codex) SSH:$($d.Ssh) RustDesk:$($d.RustDesk)")
    }
    $n=0; $answer=Read-Host $Prompt
    if (-not [int]::TryParse($answer,[ref]$n) -or $n -lt 1 -or $n -gt @($Profile.devices).Count) { throw '未选择有效设备，操作取消。' }
    return $Profile.devices[$n-1]
}
function Add-Device {
    Write-Host "`n新设备先安装 Tailscale，登录与主机相同的私人 tailnet 并连接。" -ForegroundColor Cyan
    Write-Host 'Android：Tailscale App → 登录 → 开启 VPN。Windows：官方安装器 → 托盘登录。'
    Write-Host 'Arch / NixOS：先阅读 clients/connect.sh 菜单 1 或 docs/INSTALL.zh-CN.md。电脑需要 SSH 时，先在本设备生成 Ed25519 公钥。'
    $null = Read-Host '新设备登录完成后按 Enter，向导会刷新设备列表'
    $tail = Get-AccessTailnet
    Assert-PrivateServe $tail
    $previous = Get-AccessProfile $root $tail
    Save-Profile $previous
    $peers = @($tail.Peers | Where-Object { @($_.TailscaleIPs | Where-Object { $_ -match '^100\.' }).Count } | Sort-Object HostName)
    if (-not $peers.Count) { throw '还没找到其他设备。请确认新设备已登录同一个 tailnet，稍后重新选择「添加设备」。' }
    for ($i=0;$i -lt $peers.Count;$i++) {
        $p=$peers[$i]
        Write-Host ("$($i+1). $($p.HostName) [$($p.OS)] $(@($p.TailscaleIPs | Where-Object { $_ -match '^100\.' })[0]) 在线:$($p.Online)")
    }
    $n=0; $answer=Read-Host '选择要添加 / 更新的设备序号（核对名称和 IP）'
    if (-not [int]::TryParse($answer,[ref]$n) -or $n -lt 1 -or $n -gt $peers.Count) { throw '未选择有效设备，已取消。' }
    $peer = $peers[$n-1]
    $clientIP = @($peer.TailscaleIPs | Where-Object { $_ -match '^100\.' })[0]
    $existing = @($previous.devices | Where-Object { $_.NodeId -eq $peer.ID -or $_.IP -eq $clientIP }) | Select-Object -First 1
    if ($existing -and $existing.NodeId -and $existing.NodeId -ne $peer.ID) { throw '同一地址已属于不同的旧节点。先在 Tailscale 和本向导撤销旧设备，再添加新节点。' }
    if ($existing -and $existing.IP -ne $clientIP) { throw '同一节点的地址已变化。先撤销旧地址，再重新添加。' }
    $desired = $previous | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    if ($existing) { $device = @($desired.devices | Where-Object Id -eq $existing.Id)[0] }
    else {
        $device = [pscustomobject]@{Id=[Guid]::NewGuid().ToString('N');NodeId=[string]$peer.ID;Name=[string]$peer.HostName;Platform=[string]$peer.OS;IP=$clientIP;Codex=$false;Ssh=$false;RustDesk=$false;LegacySsh=$false;PublicKey='';BrowserIds=@()}
        $desired.devices = @($desired.devices) + @($device)
    }
    $label = (Read-Host ("设备备注，留空沿用「$($device.Name)」")).Trim()
    if ($label) { $device.Name=$label }
    Write-Host '只修改选中设备，其他设备的权限与密钥会保留。已有权限默认保留。'
    $device.Codex = Confirm-Step '允许使用 Codex 网页？' -DefaultYes:([bool](-not $existing -or $device.Codex))
    $device.RustDesk = Confirm-Step '允许使用 RustDesk 远程桌面？' -DefaultYes:([bool]$device.RustDesk)
    $device.Ssh = Confirm-Step '允许 SSH / VS Code 登录 Windows（会拥有该 Windows 用户的文件权限）？' -DefaultYes:([bool]$device.Ssh)
    if ($device.Ssh -and ($device.LegacySsh -or $device.PublicKey) -and (Confirm-Step '是否更换这台设备的 SSH 公钥？通常不需要')) { $device.LegacySsh=$false; $device.PublicKey='' }
    if ($device.Ssh -and -not $device.LegacySsh -and -not $device.PublicKey) {
        $null=Export-ClientGuide $desired $device
        Write-Host '先把上述连接包复制到新设备，在新设备运行客户端脚本菜单 3。主机在这里等你；生成密钥无需先连接 SSH。只提交 .pub 公钥。'
        $keyInput = (Read-Host '粘贴 ssh-ed25519 公钥整行，或主机上 .pub 文件的完整路径').Trim().Trim('"')
        if ($keyInput.StartsWith('ssh-ed25519 ')) { $device.PublicKey=ConvertTo-PublicKey $keyInput }
        else {
            if ([IO.Path]::GetExtension($keyInput) -ne '.pub' -or (Get-Item -LiteralPath $keyInput).Length -gt 4096) { throw '请选择一个小于 4 KiB 的 .pub 公钥文件。' }
            $device.PublicKey=ConvertTo-PublicKey (Get-Content -LiteralPath $keyInput -Raw)
        }
    }
    if (-not $device.Ssh) { $device.PublicKey='';$device.LegacySsh=$false }
    if (-not ($device.Codex -or $device.Ssh -or $device.RustDesk)) { throw '未选择任何功能。要取消旧设备的所有权限，请使用「撤销设备」。' }
    $rustSource = ''
    if ($device.RustDesk -and -not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'RustDesk\RustDesk.exe'))) {
        Write-Host '主机还没有安装版 RustDesk。请从 https://rustdesk.com/ 安装；便携版也可选择其官方签名 EXE 供向导安装服务。'
        if (Confirm-Step '打开 RustDesk 官方下载页？' -DefaultYes) { Start-Process 'https://rustdesk.com/' }
        $rustSource=(Read-Host '安装完后留空；或者填写已下载的官方 RustDesk EXE 完整路径').Trim().Trim('"')
        if ($rustSource -and -not (Test-Path -LiteralPath $rustSource -PathType Leaf)) { throw '未找到 RustDesk EXE。' }
        if (-not $rustSource -and -not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'RustDesk\RustDesk.exe'))) { throw '请先完成安装再重试。' }
    }
    $actual=Apply-Profile $previous $desired $rustSource
    $device=@($actual.devices | Where-Object Id -eq $device.Id)[0]
    if ($existing -and $existing.Codex -and -not $device.Codex) {
        $browsers=@(Get-Browsers)
        foreach ($id in @($device.BrowserIds)) {
            if (@($browsers | Where-Object id -eq $id).Count) {
                & node.exe (Join-Path $root 'runtime\access-devices.mjs') revoke (Join-Path $root 'state\devices.json') $id | Out-Null
                if ($LASTEXITCODE -ne 0) { throw '系统权限已保存，但浏览器撤销未完成。请从设备列表单独检查。' }
            }
        }
        if (-not @($device.BrowserIds).Count) { Write-Warning '旧设备没有关联浏览器：还需在浏览器配对列表撤销对应授权，并保存云端规则。仅关闭此处的 Codex 标记不能撤销未关联的浏览器。' }
        $device.BrowserIds=@(); Save-Profile $actual
    }
    $null=Export-ClientGuide $actual $device
    Show-Policy $actual
    Write-Host ("新设备固定入口：https://$($actual.host.DNS)/。RustDesk：$($actual.host.IP):21118。SSH：$($actual.host.User)@$($actual.host.IP)。")
    if ($device.RustDesk) { Write-Host '在主机 RustDesk → 设置 → 安全里私下设置固定密码；新设备用上述 Tailscale 地址连接并输入密码。不要把密码交给向导。' }
    if ($device.Codex -and (Confirm-Step '现在生成此设备的 Codex 单次配对链接？' -DefaultYes)) { Pair-Browser $actual $device }
    Write-Host '最后在新设备实际检查已选功能：Codex 能看到旧对话、SSH 能运行 whoami、RustDesk 能显示桌面。未完成的项目请按连接包继续操作。'
}
function Show-Devices {
    $tail=Get-AccessTailnet
    $profile=Get-AccessProfile $root $tail
    Write-Host "`n已记录的物理设备：" -ForegroundColor Cyan
    $profile.devices | Select-Object Name,Platform,IP,Codex,Ssh,RustDesk,LegacySsh | Format-Table -AutoSize
    Write-Host '已批准的 Codex 浏览器（同一设备可能有多个浏览器；此列表不含主机连接器）：'
    @(Get-Browsers) | Select-Object id,label,approvedAt | Format-Table -AutoSize -Wrap
    Write-Host '管理记录首次会导入现有 SSH / RustDesk 白名单；以前只配过 Codex 的设备，请在「添加设备」中补登记。'
}
function Revoke-Device {
    $tail=Get-AccessTailnet
    $previous=Get-AccessProfile $root $tail
    $device=Select-ProfileDevice $previous '选择要撤销的设备序号'
    Write-Host '撤销将删除此设备的 SSH 新连接权限、RustDesk 白名单，以及所选 Codex 浏览器配对。不会删除主机对话或项目。'
    Write-Host '已有 SSH / RustDesk 会话可能仍然存在；设备丢失时还需到 Tailscale 管理页删除该节点，且更换它保存过的 RustDesk 密码。'
    if (-not (Confirm-Step ("确认撤销 $($device.Name) / $($device.IP)？"))) { return }
    $browsers=@(Get-Browsers)
    $ids=@($device.BrowserIds)
    if (-not $ids.Count -and $device.Codex) {
        Write-Host '旧设备尚未关联浏览器。选择属于它的浏览器，不能凭物理设备名自动判断：'
        for ($i=0;$i -lt $browsers.Count;$i++) { Write-Host ("$($i+1). " + $browsers[$i].label + ' / ' + $browsers[$i].id) }
        $selection=(Read-Host '输入浏览器序号，多个用逗号分隔；留空跳过（旧浏览器授权会继续存在）').Trim()
        if ($selection) {
            foreach ($value in $selection.Split(',')) {
                $n=0
                if (-not [int]::TryParse($value.Trim(),[ref]$n) -or $n -lt 1 -or $n -gt $browsers.Count) { throw '浏览器序号无效，已停止撤销。' }
                $ids+= $browsers[$n-1].id
            }
        } else { Write-Warning '尚未撤销旧 Codex 浏览器。必须在 Tailscale 管理页移除节点；也可用 Manage-Remote.ps1 单独撤销正确的浏览器。' }
    }
    Write-Host '先撤销所选浏览器配对。之后若系统设置取消或失败，这些浏览器不会自动恢复；请继续完成 SSH / RustDesk 和 Tailscale 的撤销。'
    foreach ($id in @($ids | Sort-Object -Unique)) {
        if (@($browsers | Where-Object id -eq $id).Count) {
            & node.exe (Join-Path $root 'runtime\access-devices.mjs') revoke (Join-Path $root 'state\devices.json') $id | Out-Null
            if ($LASTEXITCODE -ne 0) { throw '浏览器撤销失败，停止后续步骤。' }
        }
    }
    $desired=$previous | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $desired.devices=@($desired.devices | Where-Object Id -ne $device.Id)
    $actual=Apply-Profile $previous $desired
    Show-Policy $actual
    Write-Host '请在云端规则中移除该设备原有的放行条目，再到 https://login.tailscale.com/admin/machines 删除对应节点。'
    Write-Host '本机权限已按执行结果保存；云端节点删除与已连接会话的断开仍需完成。'
    if (Confirm-Step '打开 Tailscale 设备管理页面？' -DefaultYes) { Start-Process 'https://login.tailscale.com/admin/machines' }
}
function Invoke-WizardAction([string]$Choice) {
    switch ($Choice) {
        'Check' { Show-ConnectionCheck }
        'PrepareHost' { Prepare-Host }
        'AddDevice' { Invoke-WithDeviceLock { Add-Device } }
        'Devices' { Show-Devices }
        'Pair' { Invoke-WithDeviceLock { $tail=Get-AccessTailnet; $profile=Get-AccessProfile $root $tail; $device=Select-ProfileDevice $profile '选择要配对的设备'; if(-not $device.Codex){throw '此设备没有选择 Codex 权限。'}; Pair-Browser $profile $device } }
        'Revoke' { Invoke-WithDeviceLock { Revoke-Device } }
        'Policy' { $tail=Get-AccessTailnet; Show-Policy (Get-AccessProfile $root $tail) }
        'Start' { Write-Host '请先打开 Codex 桌面 App。现在在本窗口前台运行；Ctrl+C 停止桥接。'; & (Join-Path $root 'Start.ps1') }
        'Client' { & (Join-Path $root 'clients\Connect.ps1') }
        'ExportClients' { & (Join-Path $root 'scripts\Export-Clients.ps1') }
    }
}
if ($Action -ne 'Menu') { Invoke-WizardAction $Action; return }
Write-Host "`nCodex / SSH / RustDesk 私网连接向导" -ForegroundColor Cyan
Write-Host '建议在 Windows 主机的普通 PowerShell 运行。需要提权时会先解释再弹出 UAC。'
Write-Host '主机首次使用按 1 → 2 → 3；以后添加设备选 3；平时启动桥接选 8 或直接运行 Start.ps1。'
while ($true) {
    Write-Host "`n1 检查当前环境    2 准备 Windows 主机 / 私网入口    3 添加或更新设备"
    Write-Host '4 查看设备与配对  5 生成 Codex 配对链接            6 撤销设备'
    Write-Host '7 生成 / 查看 Tailscale 访问规则                  8 本窗口启动桥接'
    Write-Host '9 这台 Windows 只作客户端                        0 退出向导'
    Write-Host '10 导出可复制到新设备的通用客户端 ZIP'
    $answer=Read-Host '输入数字'
    if ($answer -eq '0') { break }
    $choice=@{'1'='Check';'2'='PrepareHost';'3'='AddDevice';'4'='Devices';'5'='Pair';'6'='Revoke';'7'='Policy';'8'='Start';'9'='Client';'10'='ExportClients'}[$answer]
    if ($choice) { try { Invoke-WizardAction $choice } catch { Write-Host ("本步未完成：" + $_.Exception.Message) -ForegroundColor Red; Write-Host '可以处理报错后再次选择该项。已运行的桥接与现有项目不受向导退出影响。' } }
}
