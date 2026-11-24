# Security

## Defaults

- The bridge binds to `127.0.0.1`; it is not a LAN listener.
- Tailscale Serve supplies HTTPS inside the tailnet. Funnel and public listeners are not part of this setup.
- Browser pairing links expire after ten minutes and are single-use. Approved browser keys are stored locally; raw pairing secrets are not persisted.
- The bridge connector secret and private key are protected with Windows DPAPI under the installing user. The `state` directory is access-controlled and must remain local.
- The browser-to-bridge application channel is authenticated and encrypted. HTTPS protects the web app and pairing handshake in transit.
- SSH is optional. Its setup uses per-device Ed25519 public keys and Tailscale-scoped firewall rules; passwords and agent forwarding are disabled by default.
- Tailscale device login and browser pairing are separate controls. Only add devices to a tailnet you control.

## Private files

Do not commit `state/`, generated Tailscale policy, SSH public-key files, pairing URLs, logs, local configuration, backups, API keys, or `.env` files. The repository `.gitignore` excludes the common private locations. Review `git status` and the staged diff before publishing.

The bootstrap command downloads PowerShell code from this GitHub repository and executes it. Review `Install.ps1` first if you do not want to run the current `main` branch. The installer does not collect credentials or upload local state.

## Reporting a vulnerability

Please do not publish working pairing links, API credentials, private keys, or host logs in an issue. Use GitHub's private vulnerability reporting for this repository if available; otherwise contact the maintainer privately before public disclosure.
