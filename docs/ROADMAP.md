# Roadmap

[中文路线图](ROADMAP.zh-CN.md) | [README](README.md)

## Implemented

- QR-only credential import with user-chosen password.
- Per-device token creation and revocation through `server/tokens.json`.
- Multiple named persistent sessions per `workdir + agent`, each with separate
  chat history and resumable CLI context.
- SSE streaming for Claude Code and Codex assistant text, with throttled Web UI
  updates during long replies.
- Long-task cancellation.
- Concurrent turns on the same `workdir + agent + session` are queued.
- Theme and language switching.
- English-first active app flow with Chinese toggle.
- Drawer cleanup, machine status, and About dialog.
- Read-only quota dialog showing remaining Claude Code and Codex 5-hour and weekly quotas.
- Native OS notifications for quota-reset alerts, delivered to the system tray instead of the chat message list on Android, iOS, macOS, and Windows.
- Scheduled quota-ready messages on a dedicated **Scheduled messages** drawer
  screen: per workspace, store a prompt for the next Claude Code or Codex 5-hour
  reset; the backend sends it after the reset is detected. Syncs across devices
  in the same workspace, with a Clear action to cancel a queued message.
- More detailed backend diagnostics through `GET /api/diagnostics` and the
  machine status dialog.
- Named-domain / direct-mode production hardening guide for stable public
  deployments beyond quick tunnels.
- Work directory management from the app, stored per device and sent to the
  backend on each request.
- Workdir-scoped file browsing, upload, and download from the app/Web client.
- Protected APIs reject requests when no token has been generated yet.
- Platform-separated backend setup under `backends/`, with Linux PM2 setup,
  macOS LaunchAgent setup, and Windows PowerShell/Scheduled Task setup.
- Cross-device event mirroring by workdir and selected session scope.
- Left-drawer session creation, switching, and deletion for each CLI agent.

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

- Gradually split `server/server.js` routes into focused backend route modules
  as the API surface grows, keeping the current Express behavior stable while
  reducing long-term maintenance risk.
- Offline remote push (FCM / APNs) for quota-reset alerts and scheduled-message
  results, so they arrive even when the app is fully killed. Today these rely on
  the app process being alive with the SSE stream connected; true offline push
  needs Firebase Cloud Messaging (Android) / Apple Push Notification service
  (iOS) plus a backend push sender.
- Better Antigravity quota support when an API or reliable CLI source is
  available. **Evaluated 2026-06-04 (agy 1.0.5): not implemented on purpose.**
  agy is built on Gemini Code Assist (`cloudcode-pa.googleapis.com`), and its
  only quota path is the undocumented internal `v1internal` API (e.g.
  `FetchQuotaStatus` / `GetUsageAndQuota` / `v1internal/credits`). That model is
  credit-based and multi-dimensional (prompt / flow / flex / FCA credits across
  tiers, `can_buy_more_credits`), with no clean "5-hour / weekly remaining"
  value to map onto the existing usage UI, and it would require reverse-
  engineering protobuf/gRPC schemas with no stability guarantee. The in-session
  `/credits` `/limits` `/usage` slash commands are interactive-only (not
  scriptable subcommands). Revisit when Google ships an official, scriptable
  quota source; until then keep `usage.js` reporting agy as `not_available_yet`.
