# Script reference

Run Windows scripts from the deployment directory. Most checks and previews use a normal PowerShell window. A script prompts or reports an explicit reason before a system-level change needs an administrator.

## Main entry points

| File | Purpose |
| --- | --- |
| `Install.ps1` | Download the latest checksum-verified GitHub release, install prerequisites with consent, and open the setup wizard. |
| `Setup.ps1` | Interactive host setup, Tailscale device enrollment, browser pairing, policy review, clients, and revocation. |
| `Start.ps1` | Start the bridge in the current visible PowerShell window. Keep it open while remote clients need access. |
| `scripts/Manage-Remote.ps1` | Read health/device status, create a pairing link, revoke an approved browser, or request a graceful stop. |
| `scripts/Restart-Remote.ps1` | Install a verified pending app update and start the bridge in the foreground. |

## Host and device configuration

| File | Purpose |
| --- | --- |
| `scripts/Configure-Private-Access.ps1` | Preview or configure private Tailscale Serve HTTPS to the loopback bridge. Never enables Funnel. |
| `scripts/Update-Device-Access.ps1` | Apply the reviewed Windows firewall and optional SSH/RustDesk device access plan emitted by the wizard. |
| `scripts/Setup-Secure-Ssh.ps1` | Preview/apply key-only Windows OpenSSH for a specified Tailscale client and local account. Applying needs administrator PowerShell. |
| `scripts/Restore-Secure-Ssh.ps1` | Restore SSH settings from a deployment backup. |
| `scripts/Configure-Ssh-Forwarding.ps1` | Preview/apply localhost-only TCP forwarding to one explicitly named PVE IPv4 address on port 8006. Applying needs administrator PowerShell. |
| `scripts/Configure-Ssh-PowerShell.ps1` | Set or restore the PowerShell SSH default shell. Registry and service changes need administrator PowerShell. |
| `scripts/Repair-Scoop-Ssh.ps1` | Inspect or repair the narrowly scoped Scoop/sshd process mitigation conflict. It reports the security tradeoff before applying. |
| `scripts/Configure-RustDesk.ps1` | Preview/apply the optional signed RustDesk service and Tailscale-only firewall setup. Applying needs administrator PowerShell; set its permanent password in the RustDesk UI. |
| `scripts/Export-Clients.ps1` | Build a portable client ZIP from the currently reviewed local device profile. Generated archives stay in ignored `releases/`. |

## Development and support

| File | Purpose |
| --- | --- |
| `scripts/Build-Application.ps1` | Install locked npm dependencies when absent, run checks, compile the application, and refresh notices. |
| `scripts/Build-Release.ps1` | Build a deployment ZIP and SHA-256 sidecar from committed, non-private repository files. |
| `scripts/Generate-Third-Party-Notices.ps1` | Regenerate the npm dependency license inventory. |
| `scripts/Apply-Pending-Update.ps1` | Internal verified app update installer, invoked during foreground startup. |
| `scripts/Start-Remote.ps1` | Internal bridge/connector launcher, invoked by `Start.ps1`. |
| `scripts/Access-Common.psm1` | Shared validation, Tailscale discovery, policy and access-profile functions used by the wizard. |
| `clients/Connect.ps1`, `clients/connect.sh` | Portable connection guide and optional SSH client setup for Windows and Linux. |
| `tests/Onboarding.Tests.ps1` | Isolated PowerShell onboarding, validation, and script syntax checks. |

See [INSTALL.zh-CN.md](INSTALL.zh-CN.md) for guided usage and [SECURITY.md](../SECURITY.md) for the trust boundaries.
