# Roadmap

[中文路线图](ROADMAP.zh-CN.md) | [README](README.md)

## Implemented

- QR-only credential import with user-chosen password.
- Per-device token creation and revocation through `server/tokens.json`.
- Per-device, per-agent persistent sessions.
- SSE streaming for Claude Code and Codex assistant text.
- Long-task cancellation.
- Single active task per `deviceId:agentKey`.
- Theme and language switching.
- English-first active app flow with Chinese toggle.
- Drawer cleanup, machine status, and About dialog.
- Quota dialog showing remaining Claude Code and Codex 5-hour and weekly quotas.
- Native OS notifications for quota-reset alerts, delivered to the system tray instead of the chat message list.
- Work directory management from the app, persisted to backend `.env`.
- Workdir-scoped file browsing, upload, and download from the app/Web client.
- Protected APIs reject requests when no token has been generated yet.
- Platform-separated backend setup under `backends/`, with Linux PM2 setup and macOS LaunchAgent setup.

## Planned

### Cross-platform Client and Backend

Target shape:

1. Android / iOS clients connect to Linux / macOS / Windows backends.
2. A single responsive Web frontend is the desktop client for every platform. The Windows / macOS / Linux desktop apps are thin wrappers (a webview shell) around that Web frontend rather than separately built native desktop UIs, so there is one codebase to maintain across all three.
3. Each backend platform supports service installation, tunnel setup, CLI agent detection, and diagnostics.

Reuse boundaries:

- Keep HTTP/SSE APIs, QR credential format, token revocation, and session semantics platform-neutral.
- Keep Flutter chat, credentials, settings, machines, and backend client logic shared.
- Keep Node auth, sessions, concurrency, usage reporting, and agent dispatch shared.
- Put platform-specific details behind adapters: default work directory, process spawn/cancel, service manager, tunnel path/logs, shell behavior, and quota sources.

### Later Improvements

- Shared sessions keyed by `workdir + agent` instead of `deviceId + agent`, so
  every client viewing the same backend path sees the same conversation and
  in-flight agent progress. This needs a migration path for existing
  per-device history, conflict handling for simultaneous clients, and broadcast
  SSE events by session scope rather than by only one device.
- Stable tunnel/domain setup guide.
- Desktop credential import through QR image or pasted payload.
- More detailed backend diagnostics.
- Windows backend setup.
- Better Antigravity quota support when an API or reliable CLI source is available.
