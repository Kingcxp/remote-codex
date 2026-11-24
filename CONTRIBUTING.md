# Contributing

## Source layout

- `Setup.ps1`, `Start.ps1`, and `Install.ps1` are the Windows host entry points.
- `scripts/` contains the guided onboarding, Tailscale Serve, device, SSH, RustDesk, and update helpers.
- `clients/` contains portable Windows and Linux client scripts.
- `runtime/app/` contains the Codex Anywhere-derived application source and the compiled `build/` and `dist/` used by the host runtime.
- `tests/` contains Windows onboarding and client-registry checks; application tests live in `runtime/app/test/`.
- `state/`, generated access policies, keys, release archives, and host validation records are local data and are not source contributions.

## Validate changes

Use Node.js 22.12 or later. Stop the foreground bridge before rebuilding because the command refreshes files and development dependencies used by the runtime. From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Application.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Onboarding.Tests.ps1
```

The application build command runs the upstream type checks and tests, then regenerates the deployment build. Do not test against a user's live Codex bridge or tailnet when an isolated fixture can verify the behavior.

## Release hygiene

Keep changes focused, preserve the upstream application license, and document any new privilege, firewall, Tailscale, or SSH behavior. Never include local `state`, generated access policies, real IPs or tailnet hostnames, public-key files, or validation reports from a personal host. Inspect `git diff --check`, `git status`, and the complete staged diff before committing.
