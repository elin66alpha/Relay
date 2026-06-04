# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Relay is a Flutter client (Android / iOS / Web / desktop) plus a Node backend in `server/` that fronts local CLI agents (Claude Code, Codex, Antigravity `agy`). The client connects only after importing an encrypted credential QR; there is no hard-coded backend URL.

## Commands

The local dev loop is one script — use it after most changes:

```bash
./scripts/build_flow.sh   # flutter analyze+test, node --check, build web, pm2 restart, build+install debug APK
```

Run pieces individually when iterating:

```bash
flutter analyze --no-pub
flutter test --no-pub
flutter test test/credential_file_codec_test.dart          # single test file
flutter run                                                 # client against an imported credential
node --check server/server.js                               # server is plain Node, no build; syntax-check only

# Backend (managed by PM2; app names: relay-server, relay-tunnel)
cd server && npm start                                       # or: pm2 restart relay-server --update-env
cd server && npm run credential                              # (re)generate the encrypted credential QR + tokens.json entry

# Web build the backend serves itself (flags matter — see below)
flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn
```

Two build flags are load-bearing: `--no-web-resources-cdn` bundles CanvasKit locally (the gstatic CDN is unreachable on some networks and leaves the app loaded-but-blank), and `--pwa-strategy=none` disables the service worker so browsers don't serve stale frontend after a backend restart.

## Architecture

**Sessions are keyed by `workdir + agent`, not by device.** This is the central design fact and touches the whole stack:

- Each client stores its own current work directory locally and sends it on every request via the `X-Workdir` header. The server resolves it per-request (`server/lib/workdir.js` `resolveRequestWorkdir`); there is no global "current workdir" state. `RELAY_DEFAULT_DIR` is only the path a brand-new device starts from. Workdirs must be absolute.
- The session scope key is `` `${workdir}\0${agentKey}` `` (SCOPE_SEPARATOR). Two devices in the same path share one conversation, one resumable CLI session, and one history, and mirror each other live. Chat history lives on the backend (`server/lib/history.js`), never on the client — it is reloaded on open.
- Concurrent turns on the same scope are **serialized**, not rejected: `server.js` chains them through per-scope tail Promises (`scopeChains`) because the underlying `claude --resume` CLI session is single-threaded. SSE events carry a `scopeWorkdir` and only reach clients currently subscribed to that workdir.

**Agents** (`server/lib/agents.js`) spawn the real CLI tools. `runClaude` / `runCodex` / `runAgy` each take a per-request `workdir` (falling back to `getDefaultWorkdir()`) — when threading new state through agent execution, pass it via the `runAgent(..., { workdir, settings })` options, not a global. Output streams to the client over SSE (`/api/chat` with `Accept: text/event-stream`).

**Model / Effort / Permission per scope**: `server/lib/agent-options.js` is the single source of truth mapping each agent's selectable model/effort/permission options to exact CLI argv (capability-aware — agy has no model/effort). `buildArgs(agentKey, settings)` returns the argv tokens spliced into each spawn; the **defaults reproduce the historical always-bypass, no-model, no-effort behavior**, so never-configured scopes are unchanged. Selections persist per `workdir + agent` scope in `agent-settings.json` (`server/lib/agent-settings.js`, gitignored) — shared by every device in the scope, like sessions. Endpoints: `GET /api/agent-options`, `GET`+`POST /api/agent-settings`, `GET /api/agent-version`, `POST /api/agent-update` (runs `<cli> update` so newly shipped models become selectable). The client surfaces these in the chat composer's "+" drawer (`lib/features/chat/agent_controls.dart`); the model picker has an "Update CLI" button. Gotchas: Codex permission tiers use `-c sandbox_mode=` (not `-s`, which `codex exec resume` rejects) and must pin `approval_policy=never` (exec is non-interactive, so any approval prompt hangs); Claude has a native `--effort`; brand-new pinned models can be added without code via `server/models-extra.json`.

**File system** is one unified screen (`lib/features/filesystem/file_system_screen.dart`) that browses by **absolute path up to filesystem root**, sets the work path, and uploads/downloads. It uses `/api/workdir/browse` (`listAbsoluteDirectory`); download/upload accept absolute paths (`prepareDownloadAbsolute` / `resolveAbsoluteUploadTarget` in `server/lib/filesystem.js`) and enforce size caps `MAX_DOWNLOAD_BYTES` (300 MB; a folder by its uncompressed total) and `MAX_UPLOAD_BYTES` (100 MB). Folder download streams a `zip` subprocess. Downloads run through an app-level singleton `DownloadManager` (`lib/core/download/`) so progress and the completion notification survive leaving the screen; files save to the system Downloads folder with no picker — Android via a MediaStore `MethodChannel('dev.relay.app/downloads')` in `MainActivity.kt`, desktop via `getDownloadsDirectory`, Web via an anchor click (platform split in `lib/core/platform/file_saver*.dart`).

**Auth & credentials**: protected `/api/*` routes need `Authorization: Bearer <token>` (tokens in `server/tokens.json`); before any token exists they return `TOKEN_NOT_CONFIGURED`. The credential QR is an encrypted envelope (PBKDF2-SHA256 + AES-256-GCM) generated by `server/scripts/create-credential.js`; the plaintext password is never written to disk. Clients import by camera (mobile) or by pasting the payload / uploading the PNG (Web/desktop).

**Backend serves the Web build**: when `build/web/index.html` exists, `server.js` serves it on the API host/port with brotli/gzip compression (explicitly including `application/wasm`) and smart caching (`canvaskit/*` immutable, everything else `no-cache` + ETag).

**Chat sessions, quota watch & diagnostics**: under each `workdir + agent` context there can be up to 8 named chat sessions (`server/lib/chat-sessions.js`); the scope key becomes `` `${workdir}\0${agent}\0${sessionId}` `` and the default `Main` session reuses the legacy context key (no history migration) and can't be deleted. A background quota watcher (`server/lib/quota-watch.js`) polls Claude/Codex 5-hour usage; on a detected reset it broadcasts `quota_reset` over SSE and fires any due **scheduled messages** (`server/lib/quota-schedules.js`) — drafts that auto-send to a session after the reset. These are authored on a dedicated **Scheduled messages** left-drawer screen (`lib/features/quota/quota_scheduler_screen.dart`: one row per claude/codex showing the agent, its next reset time, a message box, Send, and a Clear button when one is queued); the usage dialog (`bot_chat_screen.dart`) is read-only. One schedule may be pending **per source per workdir** (`409 SCHEDULE_EXISTS`, or pass `replaceExisting: true` to overwrite the existing one in place — what the screen's Send does); because a reset is one host-wide event, every workdir's schedule for that source fires on the same reset. The runner serializes through the same `scopeChains` as live turns, marks itself `running` before any `await` (so an overlapping watcher tick can't double-send), reconciles stuck `running` rows to `failed` on startup, and prunes finished rows. Schedule create/cancel/sent/failed broadcast `quota_schedule_*` SSE events (workdir-scoped via `sendEvent`) so other devices in the same workspace re-sync. `GET /api/diagnostics` (`server/lib/diagnostics.js`) returns a host/runtime snapshot for the machine status dialog. `quota-schedules.json` is secret state — do not commit.

**Networking modes** (chosen at setup in `backends/{linux,macos,windows}/`): direct public address, named Cloudflare Tunnel, or Cloudflare Quick Tunnel. `server/ecosystem.config.js` reads `RELAY_TUNNEL_MODE` / `CLOUDFLARED_BIN` / `CLOUDFLARED_ARGS` to decide whether/how PM2 runs the tunnel. Quick Tunnel URLs rotate on restart, so the credential must be regenerated after a URL change.

## Gotchas

- Every APK is debug-signed (no release keystore). An APK built on one machine cannot update an install signed by another; uninstall first with `adb uninstall dev.relay.app` (this clears local data).
- `server/.env`, `server/tokens.json`, `server/chat-history*.json`, and `server/credentials/` are environment/secret state — do not commit them.
- The `agy` (Antigravity) agent's quota/login state cannot always be detected; the API reports it as unknown/unavailable rather than false.
