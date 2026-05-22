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
- Drawer cleanup, machine status, and About dialog.
- Quota dialog showing remaining Claude Code and Codex 5-hour and weekly quotas.
- Work directory management from the app, persisted to backend `.env`.

## Planned

### Cross-platform Client and Backend

Target shape:

1. Android / iOS clients connect to Linux / macOS / Windows backends.
2. Linux / macOS / Windows desktop clients connect to Linux / macOS / Windows backends.
3. Each backend platform supports service installation, tunnel setup, CLI agent detection, and diagnostics.

Reuse boundaries:

- Keep HTTP/SSE APIs, QR credential format, token revocation, and session semantics platform-neutral.
- Keep Flutter chat, credentials, settings, machines, and backend client logic shared.
- Keep Node auth, sessions, concurrency, usage reporting, and agent dispatch shared.
- Put platform-specific details behind adapters: default work directory, process spawn/cancel, service manager, tunnel path/logs, shell behavior, and quota sources.

### Later Improvements

- Stable tunnel/domain setup guide.
- Desktop credential import through QR image or pasted payload.
- More detailed backend diagnostics.
- Better Antigravity quota support when an API or reliable CLI source is available.
