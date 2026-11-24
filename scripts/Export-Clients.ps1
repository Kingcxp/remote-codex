[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'Access-Common.psm1') -Force -DisableNameChecking
$tail=Get-AccessTailnet
Assert-PrivateServe $tail
$profile=Get-AccessProfile $root $tail
$fingerprint=Get-AccessHostFingerprint $root
$release=Join-Path $root 'releases'
[void](New-Item -ItemType Directory -Path $release -Force)
$archivePath=Join-Path $release 'Codex-Clients.zip'
$temporary=$archivePath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::Open($temporary,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach($file in @('Connect.ps1','connect.sh')) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $root ('clients\'+$file)),('Codex-Clients/'+$file),[IO.Compression.CompressionLevel]::Optimal) }
    $connection="HostName=$($tail.DNS)`nHostIP=$($tail.IP)`nSSHUser=$($profile.host.User)`nFingerprint=$fingerprint`n"
    $guide=@"
# 新设备从这里开始

这是连接当前 Windows 主机的客户端包，不包含权限或密码。可复制整个 ZIP 到自己的新设备并解压。
主机固定入口：https://$($tail.DNS)/
主机 Tailscale IPv4：$($tail.IP)
Windows SSH 用户：$($profile.host.User)
主机 Ed25519 指纹：$(if($fingerprint){$fingerprint}else{'尚未导出，首次 SSH 时先从主机管理员核对指纹'})

1. 新设备安装 Tailscale（https://tailscale.com/download），登录主机同一个私人 tailnet 并开启连接。
2. 新 Windows：在解压目录打开普通 PowerShell，运行：
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Connect.ps1
   Arch / NixOS：在解压目录运行 bash ./connect.sh。菜单 1 提供对应系统的准备步骤。
3. 电脑需要 SSH 时，选菜单 3 生成本设备独立密钥，建议设置口令。只把输出的 .pub 公钥交给主机；不外传私钥。
4. 在主机运行 Setup.ps1，选 3 添加设备，核对名称和 Tailscale IP，选择 Codex / SSH / RustDesk 权限。
   按向导保存 tailnet 访问规则，并把公钥粘贴回主机。需要系统管理员时会明确解释。
5. Codex：主机按提示生成单次配对链接，在新设备的浏览器打开。十分钟内有效、仅用一次。
   配对后固定地址可继续使用。Android 使用 Chrome，成功后菜单「安装应用 / 添加到主屏幕」。
6. RustDesk：主机先启用并私下设置固定密码，新设备安装官方客户端，在远程设备 ID 填 $($tail.IP):21118。
7. SSH：主机添加公钥后，客户端菜单 5 登录；首次核对上面的主机指纹再输入 yes。
   菜单 3 还会生成独立 ssh-config；VS Code Remote - SSH 可选择此配置文件连接 codex-win。

Android 不需要运行脚本：安装 Tailscale、Chrome、按需 RustDesk，按步骤 4、5、6 完成。
手机不能打开临时链接时，先确认 Tailscale 已连接且固定网址能打开；过期链接在主机重新生成。
主机须保持开机联网。Codex 还需要桌面 App 和前台 Start.ps1 窗口；退出设置向导不会停止它。
设备丢失时，在主机撤销设备，并在 Tailscale 管理页删除节点；保存过 RustDesk 密码时更换密码。
不要把主机 state 文件夹或整个服务目录复制到客户端。跨主机搬迁应使用服务安装包并重新配对。
"@
    $html='<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>新设备连接指南</title><style>body{font:16px/1.7 system-ui;max-width:880px;margin:24px auto;padding:0 20px}pre{white-space:pre-wrap;overflow-wrap:anywhere}</style><h1>新设备连接指南</h1><p><a href="https://'+$tail.DNS+'/">打开 Codex</a> · <a href="https://tailscale.com/download">安装 Tailscale</a> · <a href="https://rustdesk.com/">安装 RustDesk</a></p><pre>'+[Net.WebUtility]::HtmlEncode($guide)+'</pre></html>'
    foreach($item in @(@('connection.txt',$connection),@('START-HERE.md',$guide),@('START-HERE.html',$html))) {
        $entry=$archive.CreateEntry('Codex-Clients/'+$item[0],[IO.Compression.CompressionLevel]::Optimal)
        $writer=[IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
        try { $writer.Write([string]$item[1]) } finally { $writer.Dispose() }
    }
} finally { $archive.Dispose() }
if (Test-Path -LiteralPath $archivePath) { [IO.File]::Replace($temporary,$archivePath,[NullString]::Value) }
else { [IO.File]::Move($temporary,$archivePath) }
[IO.File]::WriteAllText(($archivePath+'.sha256'),(Get-FileHash -LiteralPath $archivePath).Hash.ToLowerInvariant()+'  Codex-Clients.zip'+"`n",[Text.UTF8Encoding]::new($false))
Write-Host ("客户端安装包已生成：$archivePath") -ForegroundColor Green
Write-Host '包里只有客户端脚本、主机地址和公开指纹；没有配对凭据、密码、API 密钥或私钥。复制到新设备解压后，从 START-HERE.html 开始。'
