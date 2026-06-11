# Roadmap

[中文路线图](ROADMAP.zh-CN.md) | [README](../README.md)

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
- Native Flutter desktop frontend for Windows, with a verified release build,
  sharing client code with mobile and Web.
- Offline remote push (Web Push for Web, Firebase Cloud Messaging for Android)
  for quota-reset alerts and scheduled-message results, with a per-device opt-in
  preference, so they arrive even when the app process is fully killed and the
  SSE stream is gone.
- Backend hot-path refactors that landed with dedicated tests: a shared
  `runAgentTurn` module (`server/lib/agent-turn.js`) used by both `/api/chat` and
  the scheduled-message runner; a `history.js` in-memory cache with debounced
  disk writes instead of full re-read/re-write on every streaming delta; and a
  single `resolveAgentScope(req, res)` replacing the duplicated agent-scope
  preamble across the request handlers.
- Full backend integrity pass (23 audited findings fixed): cached atomic JSON
  stores, timing-safe token checks, file-API sensitive-path denylist plus an
  optional `RELAY_FS_ROOTS` allowlist, streaming uploads, outbound-request
  timeouts, a stronger credential KDF, and `server.js` split into per-domain
  route modules under `server/routes/`.
- Full frontend integrity pass (16 audited findings resolved): credential
  decryption and large history decoding moved off the UI isolate, an idle
  timeout on the shared SSE event stream so dead connections reconnect,
  buffered streaming deltas, cached credential/device/workdir stores, lazy
  file lists, streaming native uploads, and a shared API transport reused by
  all backend callers.

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

- Apple Push Notification service (APNs) for iOS, to extend the existing offline
  push (Web Push + FCM) to fully-killed iOS apps.
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
