# Remote Codex

Remote Codex connects phones and Linux computers to an already-running Codex desktop app over a private [Tailscale](https://tailscale.com/) network. It does not require a public IP, a purchased domain, or an OpenAI-hosted Codex account. The Codex desktop app remains the execution host, so an existing compatible API-provider setup stays on that computer.

The supported host is Windows. The bridge listens on loopback; Tailscale Serve provides private HTTPS, and each browser pairs with a short-lived, single-use link. Android uses the installable web app. Linux clients can use the browser and, optionally, key-only SSH to the Windows host.

## Install on the Windows Codex host

Open PowerShell as your normal user and run:

```powershell
irm https://raw.githubusercontent.com/Kingcxp/remote-codex/main/Install.ps1 | iex
```

The installer downloads the latest tagged deployment archive, verifies its SHA-256 checksum, and installs it into a new folder without overwriting an existing installation. It checks for Tailscale and Node.js and asks before installing missing dependencies. Installing Tailscale may request Windows administrator approval because it adds a network adapter and system service. Sign in to the same private tailnet used by your other devices. The setup menu explains the remaining host and Serve steps; it never enables Funnel.

For a manual install, download the repository ZIP from GitHub, extract it to a new folder, and run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1` from that folder. Releases are built from the tagged commit after the Windows and application test jobs pass.

## Connect devices

On the Windows host, choose **Add a device** in `Setup.ps1` to create its per-device access entry and optional SSH/RustDesk configuration. For Codex in a new browser, choose **Pair browser** and open the fresh link on that device while Tailscale is connected. A pairing link expires after ten minutes and works once. After pairing, bookmark the fixed private HTTPS address and install it from the browser menu on Android or Linux.

The Windows bridge runs in a visible PowerShell window. Keep it open while remote access is needed. Existing desktop Codex tasks continue if the bridge stops, but remote clients disconnect until it starts again.

In the composer, **Enter** queues a message, **Shift+Enter** inserts a newline, and **Ctrl+Enter** immediately guides the current task (or starts a turn when idle; Command+Enter also works on macOS). With an empty composer, **Up/Down** recalls up to 200 successfully submitted inputs saved in that browser, including after a refresh. Editing a draft restores ordinary cursor navigation.

Queue acceptance confirms durable storage on Windows; messages are delivered in order after the current turn finishes. Temporary connection failures retry automatically. An uncertain delivery remains held for review to avoid sending the same instruction twice. Refresh the remote page after an update; existing pairings remain valid.

## Guides

- [Chinese installation and device guide](README.zh-CN.md)
- [Security model and safe defaults](SECURITY.md)
- [PowerShell script reference](docs/SCRIPTS.md)
- [Development and release packaging](CONTRIBUTING.md)
- [Upstream and third-party notices](THIRD_PARTY_NOTICES.md)

## Build and test

With Node.js 22.12 or later and npm, stop the foreground bridge first, then build the bundled application and run its checks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Application.ps1
```

Run Windows onboarding checks separately with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Onboarding.Tests.ps1
```

## License

The deployment scripts and project documentation are licensed under MIT. The bundled Codex Anywhere application retains its upstream MIT notice in [`runtime/app/LICENSE`](runtime/app/LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the application and dependency notices.
