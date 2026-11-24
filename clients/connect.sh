#!/usr/bin/env bash
# Run with: bash ./connect.sh. Reads data only; never sources connection.txt.
set -euo pipefail
client_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
codex_host=''; codex_ip=''; codex_user=''; fingerprint=''
if [[ -f "$client_dir/connection.txt" ]]; then
  seen=' '
  while IFS='=' read -r field value || [[ -n "$field" ]]; do
    field=${field%$'\r'}; value=${value%$'\r'}
    [[ -z "$field" || "$field" == \#* ]] && continue
    [[ "$seen" != *" $field "* ]] || { printf 'Duplicate connection setting\n' >&2; exit 1; }
    seen+="$field "
    case "$field" in
      HostName) codex_host=$value;; HostIP) codex_ip=$value;; SSHUser) codex_user=$value;; Fingerprint) fingerprint=$value;;
      *) printf 'Invalid connection.txt field\n' >&2; exit 1;;
    esac
  done < "$client_dir/connection.txt"
fi
[[ -n "$codex_host" ]] || read -r -p '主机完整 ts.net 名称（不含 https://）: ' codex_host
[[ -n "$codex_ip" ]] || read -r -p '主机 Tailscale IPv4（100.x.x.x）: ' codex_ip
[[ -n "$codex_user" ]] || read -r -p 'Windows 用户名（例如 windowsuser）: ' codex_user
trim_input() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}
codex_host=$(trim_input "$codex_host"); codex_ip=$(trim_input "$codex_ip"); codex_user=$(trim_input "$codex_user")
# Accept a copied private HTTPS root URL, but never a path, port, query or credentials.
if [[ "$codex_host" =~ ^https://([a-zA-Z0-9.-]+)/?$ ]]; then codex_host=${BASH_REMATCH[1]}; fi
codex_host=${codex_host%.}
[[ "$codex_host" =~ ^[a-zA-Z0-9-]+\.[a-zA-Z0-9.-]+\.ts\.net$ ]] || { printf '主机名格式不正确：请填写 Windows 的完整 ts.net 名称，例如 codex-host.example-tailnet.ts.net；也可粘贴 https://codex-host.example-tailnet.ts.net/。不是填写用户名。若使用 connection.txt，请检查其中的 HostName。\n' >&2; exit 1; }
[[ "$codex_user" =~ ^[a-z0-9_.-]+$ ]] || { printf 'Windows 用户名格式不正确：请填写本地账户名，例如 windowsuser，不加计算机名、反斜杠或 @主机。若使用 connection.txt，请检查其中的 SSHUser。\n' >&2; exit 1; }
[[ "$codex_ip" =~ ^100\.([0-9]{2,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || { printf 'Invalid Tailscale IPv4\n' >&2; exit 1; }
for octet in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; do
  [[ "$octet" == '0' || "$octet" != 0* ]] && ((10#$octet <= 255)) || { printf 'Invalid IPv4 octet\n' >&2; exit 1; }
done
second=${codex_ip#100.}; second=${second%%.*}
((10#$second >= 64 && 10#$second <= 127)) || { printf 'Address outside tailnet range\n' >&2; exit 1; }
[[ -z "$fingerprint" || "$fingerprint" =~ ^SHA256:[a-zA-Z0-9+/]{43}$ ]] || { printf 'Invalid SSH fingerprint\n' >&2; exit 1; }
key_file="$HOME/.ssh/id_ed25519_codex_${codex_ip//./_}"
url="https://$codex_host/"

connected() {
  command -v tailscale >/dev/null || { printf '缺少 Tailscale，请先选择 1。\n' >&2; return 1; }
  local own_ip status
  status=$(tailscale status --json) || return 1
  if ! printf '%s' "$status" | grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then printf 'Tailscale 尚未连接，请先登录并开启连接。\n' >&2; return 1; fi
  own_ip=$(tailscale ip -4) || return 1
  [[ "$own_ip" =~ ^100\. ]] || { printf 'Tailscale 尚未连接。\n' >&2; return 1; }
}
open_url() {
  printf '%s\n' "$1"
  if command -v xdg-open >/dev/null; then xdg-open "$1"; fi
}
prepare() {
  printf 'Tailscale 必须登录主机的同一个私人 tailnet。sudo 仅用于安装软件、开启系统服务和首次组网。\n'
  if [[ -f /etc/NIXOS ]]; then
    cat <<'NIXOS'
NixOS：在你自己维护的主机配置中合并以下内容（已有定义请合并）：
  services.tailscale.enable = true;
  environment.systemPackages = with pkgs; [ openssh curl rustdesk-flutter ];
然后在你的 flake/configuration 目录运行你平时使用的 sudo nixos-rebuild switch 命令。
本脚本不会修改你的 NixOS 项目。配置生效后执行：sudo tailscale up
NIXOS
  elif [[ -f /etc/arch-release ]]; then
    printf 'Arch 将执行 sudo pacman -Syu --needed tailscale openssh curl，然后启用 tailscaled。
这包括系统更新；如正处于升级维护期，请先按平时的流程完成更新。
'
    read -r -p '现在安装并启用？[y/N] ' confirm
    if [[ "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
      sudo pacman -Syu --needed tailscale openssh curl || return 1
      sudo systemctl enable --now tailscaled || return 1
    fi
    printf 'RustDesk 请用官方发行版，见 https://rustdesk.com/；不自动安装 AUR 软件。\n'
  else
    printf '请按你的发行版官方说明安装 Tailscale、OpenSSH 客户端、curl 和 RustDesk：
https://tailscale.com/download/linux
https://rustdesk.com/
'
  fi
  if command -v tailscale >/dev/null; then
    read -r -p '现在运行 sudo tailscale up 并按链接登录？[y/N] ' confirm
    if [[ "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then sudo tailscale up || return 1; fi
  fi
  printf '登录后记下 tailscale ip -4，在 Windows 主机的 Setup.ps1 添加这台设备。\n'
}
make_key() {
  command -v ssh-keygen >/dev/null || { printf '请先安装 OpenSSH 客户端。\n' >&2; return 1; }
  (umask 077; mkdir -p "$HOME/.ssh")
  if [[ ! -f "$key_file" ]]; then
    [[ ! -e "$key_file.pub" ]] || { printf '只存在同名公钥；停止以避免覆盖。\n' >&2; return 1; }
    printf '生成本设备独立密钥；建议设置口令，输入时不显示字符。\n'
    ssh-keygen -t ed25519 -a 64 -f "$key_file" -C "codex-$(hostname)" || return 1
  fi
  [[ -f "$key_file.pub" ]] || { printf '公钥丢失，请恢复公钥，不要覆盖私钥。\n' >&2; return 1; }
  printf '\n把下一行公钥交给 Windows Setup.ps1 → 添加设备。不要发送私钥。\n'
  cat -- "$key_file.pub"
  ssh-keygen -lf "$key_file.pub" || return 1
  (umask 077; cat > "$client_dir/ssh-config" <<SSHCONFIG
Host codex-win
    HostName $codex_ip
    User $codex_user
    IdentityFile "$key_file"
    IdentitiesOnly yes
    StrictHostKeyChecking ask
    ServerAliveInterval 30
    ServerAliveCountMax 3
SSHCONFIG
  )
  printf '独立配置已写入 %s/ssh-config；已有 ~/.ssh/config 未改动。\n' "$client_dir"
}
check_access() {
  connected || return 1
  command -v curl >/dev/null || { printf '请安装 curl。\n' >&2; return 1; }
  printf '检查私网 HTTPS；保留正常证书验证。\n'
  curl --fail --silent --show-error --max-time 10 "${url}health" || return 1
  printf '\nHTTPS 可达；SSH / RustDesk 仍需各自登录验证。\n'
}
ssh_login() {
  connected || return 1
  if [[ ! -f "$key_file" ]]; then make_key || return 1; printf '请先把公钥添加到主机，再选 SSH 登录。\n'; return; fi
  if [[ -n "$fingerprint" ]]; then printf '首次连接必须核对主机指纹：%s\n' "$fingerprint"
  else printf '先从主机管理员取得 Ed25519 主机指纹，核对一致后才能输入 yes。\n'; fi
  ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=ask -o ServerAliveInterval=30 -i "$key_file" -l "$codex_user" "$codex_ip" || return 1
}
while true; do
  printf '\n连接 %s（Linux 客户端）\n1 准备软件 / 登录 Tailscale\n2 检查连接\n3 生成 / 显示 SSH 公钥\n4 打开 Codex\n5 SSH 登录\n6 RustDesk 连接\n0 退出\n' "$codex_host"
  read -r -p '输入数字: ' choice || break
  choice=${choice%$'\r'}
  case "$choice" in
    1) prepare || printf '准备未完成，请按报错处理后重试。\n';;
    2) check_access || printf '连接未通过；请检查 Tailscale 登录、主机前台桥接和 tailnet 访问规则。\n';;
    3) make_key || printf '密钥步骤未完成。\n';;
    4) if connected; then open_url "$url" || true; printf '首次在主机生成单次配对链接，用此浏览器打开；以后用固定地址。\n'; fi;;
    5) ssh_login || printf 'SSH 未成功，请保留完整报错，勿关闭主机防火墙或禁用主机指纹验证。\n';;
    6) if connected; then printf 'RustDesk 远程设备 ID 填 %s:21118，连接后输入主机的固定密码。\n' "$codex_ip"; if command -v rustdesk >/dev/null; then rustdesk --connect "$codex_ip:21118" || true; else open_url 'https://rustdesk.com/' || true; fi; fi;;
    0) break;;
    *) printf '请输入菜单中的数字。\n';;
  esac
done
