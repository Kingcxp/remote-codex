# Remote Codex

Remote Codex 让 Android 手机和 Linux 电脑通过私人 Tailscale 网络查看、继续本机 Codex 桌面 App 中的对话。Windows 是运行 Codex 桌面 App 和桥接服务的主机。无需公网 IP、购买域名或官方 OpenAI Codex 登录；已有的兼容 API 提供商配置仍保留在 Windows 桌面 App 中。

桥接只监听本机回环地址，由 Tailscale Serve 提供 tailnet 私有 HTTPS。浏览器需使用短时、单次配对链接授权。Android 和 Linux 使用可安装网页应用；Linux 也可按需配置仅公钥 SSH。

## 一条命令启动安装向导

在运行 Codex 桌面 App 的 Windows 电脑上，以**普通用户**打开 PowerShell：

```powershell
irm https://raw.githubusercontent.com/Kingcxp/remote-codex/main/Install.ps1 | iex
```

引导器会下载最新标记版本的部署包、校验 SHA-256，并安装到新目录；遇到已有安装时不会覆盖。它检查 Tailscale 和 Node.js，并在安装缺少的软件前询问你。安装 Tailscale 可能弹出 UAC，因为它需要安装虚拟网卡和系统服务。完成后登录你的私人 tailnet，再按菜单提示配置本机桥接与私网 HTTPS。脚本不会启用 Funnel，也不会把桥接端口直接暴露到局域网或公网。GitHub 只会在 Windows 与应用测试通过后生成正式发布包。

已有下载包时，也可解压到一个新目录后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
```

详细步骤见[安装与设备指南](docs/INSTALL.zh-CN.md)。

## 连接手机或 Linux 电脑

先在 Windows 向导中选择添加设备。让新设备登录同一个私人 Tailscale 网络，随后在 Windows 生成新的浏览器配对链接，并在新设备浏览器中打开。链接十分钟后过期且只能使用一次；配对后收藏固定的 `.ts.net` 地址。Android Chrome 和 Linux Chromium 均可将网页安装为应用。

Windows 桥接在可见的 PowerShell 窗口前台运行。需要远程访问时保持窗口打开。停止桥接不会停止桌面 Codex 已在执行的任务，但手机和 Linux 暂时无法连接。

输入框中按 **Enter** 将消息加入队列，**Shift+Enter** 换行，**Ctrl+Enter** 立即引导当前任务（空闲时开始新一轮；macOS 可用 Command+Enter）。输入框为空时按 **↑ / ↓** 浏览本浏览器成功提交过的最近 200 条输入，选中后可编辑或再次发送；刷新仍会保留。已有草稿时方向键保持普通光标操作。

排队确认表示消息已保存到 Windows，当前任务完成后才会依次投递。连接暂时不可用时保留队列并自动重试；若显示“发送结果待确认”，请先核对对话，避免重复提交。更新桥接后刷新远程网页即可，无需重新配对。

## 项目文档

- [安装、Tailscale 配置和各平台使用说明](docs/INSTALL.zh-CN.md)
- [脚本功能索引](docs/SCRIPTS.md)
- [安全模型与默认限制](SECURITY.md)
- [开发、测试和发布](CONTRIBUTING.md)
- [上游项目与第三方许可证](THIRD_PARTY_NOTICES.md)

部署代码与文档采用 MIT 许可证；内置 Codex Anywhere 保留上游 MIT 许可证。请参阅[许可证](LICENSE)和第三方声明。
