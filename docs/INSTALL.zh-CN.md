# 安装与设备指南

Remote Codex 的 Windows 主机运行 Codex 桌面 App 与桥接。Android、Arch、Debian 和 NixOS 是 Tailscale 客户端，可通过私网 HTTPS 查看同一主机中的 Codex 对话。无论桌面 App 使用哪家兼容 API 服务商，凭据都留在 Windows 用户本机。

## 1. 安装 Windows 主机

在运行 Codex 桌面 App 的 Windows 电脑打开普通 PowerShell：

```powershell
irm https://raw.githubusercontent.com/Kingcxp/remote-codex/main/Install.ps1 | iex
```

引导器检查 Node.js 22.12+ 与 Tailscale，并在缺失时询问是否从 winget 安装。Tailscale 虚拟网卡和系统服务需要 Windows 安装权限，可能出现 UAC。若系统没有 winget，会打开官方安装页。安装后在 Tailscale 托盘应用登录你控制的私人 tailnet，Windows 和所有客户端都登录同一个 tailnet。

安装器下载到 `C:\Users\<用户名>\Remote-Codex`，目录已存在时会保留原文件并打开现有向导。也可从 GitHub 下载 ZIP 解压到新目录，运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
```

向导中：

1. 选择 **Prepare this host**，确认本机 Codex 桌面 App 可用，并选择一个已有工作目录。向导保存的目录用于远程新建 Codex 任务。
2. 选择 **Start bridge**。桥接会在前台 PowerShell 可见窗口运行，不注册后台服务；依赖首次下载完成后，看到 `[bridge] Ready`。
3. 选择 **Configure private access**，把 Tailscale Serve 指向 `http://127.0.0.1:3300`。如果 Tailscale 要求启用 HTTPS，在管理页确认授权后重试。不要开启 Funnel。Serve 只在 tailnet 内提供 HTTPS，不需要公网地址或自购域名。
4. 在 Tailscale 管理控制台检查设备审批及访问策略。访问策略是独立于浏览器配对的网络层控制；向导会生成策略供你审核，不会使用管理 API 密钥替你写入云端。

主机桥接窗口必须保持打开。重启电脑后，再以同一 Windows 用户运行部署目录中的 `Start.ps1`。

## 2. 添加 Android 或 Linux 客户端

1. 在客户端安装 Tailscale 并登录同一个 tailnet。确认 Tailscale 显示 Connected。部分 tailnet 要管理员批准新设备。
2. 在 Windows 主机运行 `Setup.ps1`，选择 **Add a device**。输入设备名称，并只选择确实需要的功能。Codex 浏览器配对、SSH 公钥访问和 RustDesk 是各自独立的授权。
3. 需要打开浏览器时，在 Windows 向导选择 **Pair browser**，每台新设备各生成一条链接。链接十分钟有效且仅可使用一次。不要把链接放入 Git、截图、公开聊天或收藏夹。
4. 在 Android Chrome、Linux Chromium/Firefox 打开新链接，按网页提示完成配对。成功后收藏固定的 `https://<Windows 主机名>.<tailnet>.ts.net/` 地址；Android 浏览器菜单提供“安装应用”或“添加到主屏幕”。收藏固定入口，而不是一次性配对链接。

后续只需连接 Tailscale，打开固定入口即可。换浏览器、清除站点数据或重装系统会更换设备密钥，需要在 Windows 重新生成配对链接。

Linux 也可通过客户端包生成 Ed25519 SSH 密钥。在 `Setup.ps1` 为该设备启用 SSH 后，把公钥登记到 Windows；私钥留在 Linux。Windows SSH 设置会展示系统权限和防火墙改动，应用它需要管理员 PowerShell。VS Code Remote-SSH 的本机 TCP 转发是单独的可选设置。

## 3. RustDesk（可选）

只有需要图形桌面时才设置 RustDesk。先在 Windows 安装并打开 RustDesk，再从部署包运行 `scripts/Configure-RustDesk.ps1 -Apply`。配置服务和防火墙需要管理员权限；脚本不处理或输出固定密码。之后在 RustDesk 安全设置界面自行设固定密码，并只允许已批准的 Tailscale 客户端设备。

## 常用管理

在部署目录打开第二个普通 PowerShell：

```powershell
.\scripts\Manage-Remote.ps1 -Action Status
.\scripts\Manage-Remote.ps1 -Action Pair
.\scripts\Manage-Remote.ps1 -Action Devices
```

`Pair` 命令会先验证私网 HTTPS，然后生成一次性链接和二维码。重新生成链接也能解除浏览器的失败尝试锁定。不要在手机网页提示限流时反复提交旧链接。

更新桥接前请先把更改的部署文件备份好；正常桥接重启命令为：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Restart-Remote.ps1
```

运行时目录 `state/` 包含本机配对、授权、加密队列和 DPAPI 凭据，必须保留在本地并纳入可靠的加密备份策略；不要放入公开同步盘或 Git。

## 故障排查

- 页面无法打开：确认两端 Tailscale 已连接、主机前台出现 `[bridge] Ready`，并且 Tailscale Serve 的 HTTPS 目标为 `http://127.0.0.1:3300`。
- 浏览器显示配对错误：在 Windows 运行 `Manage-Remote.ps1 -Action Pair` 生成新链接。每条链接只可用一次。
- 页面可开但无法连接：刷新网页并检查 Tailscale 管理策略是否允许该客户端访问主机 TCP 443。桥接本身的 TCP 3300 不应开放给 tailnet。
- 无法看到 Codex 对话：确认 Codex 桌面 App 和 bridge 以同一个 Windows 用户运行；在第二个 PowerShell 窗口查看 `Manage-Remote.ps1 -Action Status`。
- SSH 失败：先检查对应设备 Tailscale IP、公钥、Windows `sshd` 状态和 SSH 主机指纹；不要为排错开放密码认证或公网 SSH。
