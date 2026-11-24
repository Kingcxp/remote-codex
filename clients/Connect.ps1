[CmdletBinding()]
param(
    [string]$HostName,
    [string]$HostIP,
    [string]$SSHUser,
    [ValidateSet('Menu','Check','Prepare','Key','Codex','Ssh','RustDesk')][string]$Action='Menu'
)
$ErrorActionPreference = 'Stop'
$fingerprint = ''
$config = Join-Path $PSScriptRoot 'connection.txt'
if (Test-Path -LiteralPath $config) {
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $config) {
        if ($line -match '^(HostName|HostIP|SSHUser|Fingerprint)=(.*)$') {
            if ($values.ContainsKey($Matches[1])) { throw 'Duplicate connection setting.' }
            $values[$Matches[1]] = $Matches[2]
        } elseif ($line.Trim() -and -not $line.StartsWith('#')) { throw 'Invalid connection.txt. No commands are allowed in this file.' }
    }
    if (-not $HostName) { $HostName = $values.HostName }
    if (-not $HostIP) { $HostIP = $values.HostIP }
    if (-not $SSHUser) { $SSHUser = $values.SSHUser }
    $fingerprint = $values.Fingerprint
}
if (-not $HostName) { $HostName = (Read-Host '主机的完整 ts.net 名称（不含 https://）').Trim() }
if (-not $HostIP) { $HostIP = (Read-Host '主机的 Tailscale IPv4（100.x.x.x）').Trim() }
if (-not $SSHUser) { $SSHUser = (Read-Host 'Windows 登录账户名，例如 windowsuser').Trim() }
$HostName=$HostName.Trim(); $HostIP=$HostIP.Trim(); $SSHUser=$SSHUser.Trim()
if ($HostName -cmatch '^https://([a-zA-Z0-9.-]+)/?$') { $HostName=$Matches[1] }
$HostName=$HostName.TrimEnd('.')
if ($HostName -notmatch '^[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]+\.ts\.net$') { throw '主机名格式不正确：请填写 Windows 的完整 ts.net 名称，例如 codex-host.example-tailnet.ts.net，或粘贴它的 HTTPS 入口网址。若使用 connection.txt，请检查 HostName。' }
if ($SSHUser -cnotmatch '^[a-z0-9_.-]+$') { throw 'Windows 用户名格式不正确：请填写本地账户名，例如 windowsuser，不加计算机名、反斜杠或 @主机。若使用 connection.txt，请检查 SSHUser。' }
$ip = $null
if (-not [Net.IPAddress]::TryParse($HostIP,[ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork' -or $ip.ToString() -ne $HostIP -or $ip.GetAddressBytes()[0] -ne 100 -or $ip.GetAddressBytes()[1] -lt 64 -or $ip.GetAddressBytes()[1] -gt 127) { throw '必须填写 Tailscale IPv4。' }
if ($fingerprint -and $fingerprint -notmatch '^SHA256:[A-Za-z0-9+/]{43}$') { throw 'Invalid SSH fingerprint.' }
$keyPath = Join-Path $env:USERPROFILE ('.ssh\id_ed25519_codex_' + $HostIP.Replace('.','_'))
$sshConfigPath = Join-Path $PSScriptRoot 'ssh-config'

function Get-ClientTailscale {
    $path = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $path) { return $path }
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw '请先选择「准备软件」安装并登录 Tailscale。'
}
function Assert-ClientConnected {
    $ts = Get-ClientTailscale
    $raw = & $ts status --json
    if ($LASTEXITCODE -ne 0 -or ($raw | ConvertFrom-Json).BackendState -ne 'Running') { throw 'Tailscale 尚未连接。请打开 Tailscale 登录主机所属的同一个账户 / tailnet。' }
    $tail = $raw | ConvertFrom-Json
    $nodes = @($tail.Self)
    if ($tail.Peer) { $nodes += @($tail.Peer.PSObject.Properties | ForEach-Object Value) }
    if (-not @($nodes | Where-Object { $_.TailscaleIPs -contains $HostIP -and ([string]$_.DNSName).TrimEnd('.') -eq $HostName }).Count) { throw '未在当前 tailnet 找到匹配的主机 IP 和名称，请核对登录账户及 connection.txt。' }
}
function New-ClientKey {
    $null = Get-Command ssh-keygen.exe -ErrorAction Stop
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $keyPath) -Force)
    if (-not (Test-Path -LiteralPath $keyPath)) {
        if (Test-Path -LiteralPath ($keyPath + '.pub')) { throw '只存在同名公钥，停止以避免覆盖。请先检查旧文件。' }
        Write-Host '现在生成仅属于这台设备的 SSH 密钥。建议输入密钥口令；输入时不显示字符。不要把私钥发给主机。'
        & ssh-keygen.exe -t ed25519 -a 64 -f $keyPath -C ('codex-' + $env:COMPUTERNAME)
        if ($LASTEXITCODE -ne 0) { throw 'SSH 密钥生成失败。' }
    }
    if (-not (Test-Path -LiteralPath ($keyPath + '.pub'))) { throw '公钥文件丢失，请从私钥恢复公钥，勿创建覆盖原文件。' }
    Write-Host "`n把下面这一行公钥交给 Windows 主机的 Setup.ps1 → 添加设备：" -ForegroundColor Cyan
    Get-Content -LiteralPath ($keyPath + '.pub')
    & ssh-keygen.exe -lf ($keyPath + '.pub')
    if ($LASTEXITCODE -ne 0) { throw '公钥文件无效。' }
    $configText = "Host codex-win`n    HostName $HostIP`n    User $SSHUser`n    IdentityFile `"$($keyPath.Replace('\','/'))`"`n    IdentitiesOnly yes`n    StrictHostKeyChecking ask`n    ServerAliveInterval 30`n    ServerAliveCountMax 3`n"
    [IO.File]::WriteAllText($sshConfigPath,$configText,[Text.UTF8Encoding]::new($false))
    Write-Host "独立 SSH 配置已写入 $sshConfigPath；现有 ~/.ssh/config 未改动。"
}
function Invoke-ClientAction([string]$Choice) {
    switch ($Choice) {
        'Prepare' {
            Write-Host '安装只需做一次；Tailscale 登录与 OpenAI 登录无关。SSH 使用 Windows 自带 OpenSSH 客户端。'
            Write-Host 'Tailscale 安装程序可能请求管理员权限，因为需要安装虚拟网卡和系统服务。'
            if ((Read-Host '打开官方 Tailscale 下载页？[Y/n]') -notmatch '^(n|no|否)$') { Start-Process 'https://tailscale.com/download/windows' }
            Write-Host '安装后从系统托盘打开 Tailscale，登录主机的同一个私人 tailnet。'
            Write-Host '如需远程桌面，在 https://rustdesk.com/ 下载并安装 RustDesk；客户端不需要配置入站端口。'
            if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { Write-Host '缺少 OpenSSH 客户端：Windows 设置 → 系统 → 可选功能 → 添加 OpenSSH 客户端。此安装需要管理员。' }
        }
        'Check' {
            Assert-ClientConnected
            Write-Host 'Tailscale 已连接，正在检查主机私网 HTTPS（不跳过证书验证）……'
            $health = Invoke-RestMethod -Uri ("https://$HostName/health") -TimeoutSec 10
            if (-not $health.ok) { throw 'HTTPS 可达但桥接未就绪。' }
            Write-Host 'Codex 入口检查通过。SSH / RustDesk 仍需各自登录验证。' -ForegroundColor Green
        }
        'Key' { New-ClientKey }
        'Codex' {
            Assert-ClientConnected
            Start-Process ("https://$HostName/")
            Write-Host '首次使用：在主机 Setup.ps1 生成单次配对链接，用这台设备的浏览器打开。之后固定地址可随时使用；主机及前台桥接须保持运行。'
        }
        'Ssh' {
            Assert-ClientConnected
            if (-not (Test-Path -LiteralPath $keyPath)) { New-ClientKey; Write-Host '先在主机添加此公钥，再选择 SSH 登录。'; return }
            if ($fingerprint) { Write-Host ("第一次连接必须核对主机指纹：$fingerprint") -ForegroundColor Yellow }
            else { Write-Host '先向主机管理员索取 Ed25519 主机指纹；未核对时不要输入 yes。' -ForegroundColor Yellow }
            & ssh.exe -o IdentitiesOnly=yes -o StrictHostKeyChecking=ask -o ServerAliveInterval=30 -i $keyPath -l $SSHUser $HostIP
            if ($LASTEXITCODE -ne 0) { throw "SSH 退出码 $LASTEXITCODE。请保留完整输出，检查主机授权、公钥和 Tailscale 规则。" }
        }
        'RustDesk' {
            Assert-ClientConnected
            Write-Host ("打开 RustDesk，把「远程设备 ID」填为 ${HostIP}:21118，连接后输入在主机私下设置的固定密码。") -ForegroundColor Cyan
            Write-Host '使用这个 Tailscale 地址；不需要输入 RustDesk 数字 ID，不需要公网 IP、域名或自建中继。'
            $exe = Join-Path $env:ProgramFiles 'RustDesk\RustDesk.exe'
            if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }
            else { Start-Process 'https://rustdesk.com/' }
        }
    }
}
if ($Action -ne 'Menu') { Invoke-ClientAction $Action; return }
while ($true) {
    Write-Host "`n连接 $HostName（Windows 客户端）" -ForegroundColor Cyan
    Write-Host '1 准备软件 / 登录 Tailscale   2 检查连接   3 生成 / 显示 SSH 公钥'
    Write-Host '4 打开 Codex   5 SSH 登录   6 RustDesk 操作说明   0 退出'
    $answer = Read-Host '输入数字'
    if ($answer -eq '0') { break }
    $selected = @{ '1'='Prepare';'2'='Check';'3'='Key';'4'='Codex';'5'='Ssh';'6'='RustDesk' }[$answer]
    if ($selected) { try { Invoke-ClientAction $selected } catch { Write-Host $_.Exception.Message -ForegroundColor Red } }
}
