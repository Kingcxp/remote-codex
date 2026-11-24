# Upstream and third-party notices

## Codex Anywhere

The embedded application in `runtime/app/` is derived from [gaotong132/codex-anywhere](https://github.com/gaotong132/codex-anywhere), upstream commit `6d3e507f2eb3cb660ce6752194e78e4f48ad63f3`. Its original MIT license is preserved at [`runtime/app/LICENSE`](runtime/app/LICENSE). The application source, build, and frontend are kept together in that directory.

## npm dependencies

The application build uses packages declared in `runtime/app/package-lock.json`. Their license metadata and notices are listed in [`runtime/app/THIRD_PARTY_NOTICES.md`](runtime/app/THIRD_PARTY_NOTICES.md). Dependencies are installed from the npm registry by `npm ci`; this repository does not commit `node_modules/`.

## Tailscale and other host tools

Tailscale, Node.js, PowerShell, OpenSSH, and RustDesk are separate products. This repository does not bundle or relicense them. Install them from their official distribution channels and follow their respective terms.
