# Roadmap

[中文路线图](ROADMAP.zh-CN.md) | [README](README.md)

## Implemented

- QR-only credential import with user-chosen password.
- Per-device token creation and revocation through `server/tokens.json`.
- Shared persistent sessions keyed by `workdir + agent`.
- SSE streaming for Claude Code and Codex assistant text, with throttled Web UI
  updates during long replies.
- Long-task cancellation.
- Concurrent turns on the same `workdir + agent` session are queued.
- Theme and language switching.
- English-first active app flow with Chinese toggle.
- Drawer cleanup, machine status, and About dialog.
- Quota dialog showing remaining Claude Code and Codex 5-hour and weekly quotas.
- Native OS notifications for quota-reset alerts, delivered to the system tray instead of the chat message list.
- Work directory management from the app, stored per device and sent to the
  backend on each request.
- Workdir-scoped file browsing, upload, and download from the app/Web client.
- Protected APIs reject requests when no token has been generated yet.
- Platform-separated backend setup under `backends/`, with Linux PM2 setup,
  macOS LaunchAgent setup, and Windows PowerShell/Scheduled Task setup.
- Cross-device event mirroring by workdir scope.

## Planned

### Cross-platform Client and Backend

Target shape:

1. Android / iOS clients connect to Linux / macOS / Windows backends.
2. Windows / macOS / Linux desktop frontends are native Flutter desktop apps
   that share Flutter client code with mobile and Web.
3. Each backend platform supports service installation, named Cloudflare
   Tunnel, Cloudflare Quick Tunnel, direct public-host mode, CLI agent
   detection, and diagnostics.

Reuse boundaries:

- Keep HTTP/SSE APIs, QR credential format, token revocation, and session semantics platform-neutral.
- Keep Flutter chat, credentials, settings, machines, and backend client logic shared.
- Keep Node auth, sessions, concurrency, usage reporting, and agent dispatch shared.
- Put platform-specific details behind adapters: default work directory, process spawn/cancel, service manager, tunnel URL lookup, shell behavior, and quota sources.

### Later Improvements

- **Multiple Agent Sessions per Workdir**: Allow multiple concurrent sessions for each AI agent within the same working directory. Upon switching to a work directory, automatically load previously saved sessions (including names and conversation history/memory). Add a "New Session" (+) button in the left drawer next to the CLI agents, along with the ability to delete specific sessions.
- Named-domain / direct-mode hardening guide for production use beyond quick tunnels.
- More detailed backend diagnostics.
- Scheduled quota-ready messages: let the user draft a message tied to the next
  quota reset time, then automatically send it immediately after quota refresh
  so refreshed capacity is not wasted while the user is away.
- Better Antigravity quota support when an API or reliable CLI source is available.
