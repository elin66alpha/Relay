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
- Experimental CLI agents (OpenCode, Hermes) with binary detection, session
  resume, model/effort/permission trees, and dynamic listing — agents appear
  in the UI only when their CLI is installed on the host.
- BTW (by the way) sidekick: read-only `/api/btw` endpoint for side questions
  without disturbing the active task — Claude forks its native CLI session, while
  Codex and Antigravity run side sessions cloned from the main conversation.
- Swarm (multi-agent group chat, shown as **Swarm** / 蜂群): named swarms of agent
  members share one transcript and answer `@mentions` in turn (serialized, one
  speaker at a time; each member fed only the delta since it last spoke). Each
  swarm pins its own work tree and per-member model/effort/permission, is listed
  per workspace (several per workspace, each on its chosen work tree), and appears
  as always-visible sub-entries in the left drawer. See `docs/group-chat.md`.
- Antigravity model selection: `agy` exposes its model catalog via `--model`, so
  swarms and solo chats can pin a specific Gemini / Claude / GPT-OSS model.
- Multi-segment messages: each assistant follow-up gets its own timestamp and
  is rendered as a collapsible block in the frontend; the backend emits
  `segment` SSE events and tracks `{ ts, text }` entries in message metadata.
- Agent icons: per-agent PNG assets with light/dark variants, replacing the
  icon font glyphs in the agent drawer.

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
- Antigravity quota is now wired through the local `agy` language-server RPC
  (`RetrieveUserQuotaSummary`), which returns model-group buckets with exact
  remaining fractions for the 5-hour and weekly windows. Remaining limitation:
  the source is local to a running Antigravity CLI instance, not an official
  public REST API; `/api/usage` can use a cached value when present, otherwise it
  reports a clear "start agy once" error if the local RPC is unreachable.
