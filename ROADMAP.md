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
- Native OS notifications for quota-reset alerts, delivered to the system tray instead of the chat message list.
- Work directory management from the app, persisted to backend `.env`.

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

- **User Voice Input**: Support recording voice inputs in the chat screen and transcribing them (via Whisper API or similar) to allow hands-free developer agent interactions.
- Stable tunnel/domain setup guide.
- Desktop credential import through QR image or pasted payload.
- More detailed backend diagnostics.
- Better Antigravity quota support when an API or reliable CLI source is available.
