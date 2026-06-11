# AGENT.md - Shared Agent Notes

This file is a short handoff log and technical reference for agents working on
Relay. Keep it current, factual, and free of secrets. Detailed history lives in
git; finished work should be summarized here briefly, not narrated.

## Current Project Shape

- Flutter client for Android, iOS, Web, and desktop runner projects.
- Node.js backend in `server/`: entry `server.js` (~900 lines: config,
  middleware, shared state, schedulers, static serving) plus per-domain route
  modules in `server/routes/{meta,push,fs,chat,sessions,quota}.js` — each
  exports a `createXxxRouter(ctx)` factory receiving shared state through
  `routeContext`.
- OS setup lives in `backends/` (Linux PM2, macOS LaunchAgent, Windows
  PowerShell/Scheduled Task).
- Supported CLI agents: Claude Code, Codex, and Antigravity (`agy`).
- Clients connect by importing an encrypted credential QR / payload and entering
  the user-chosen password.
- All protected APIs require a revocable bearer token from `server/tokens.json`.
- Sessions are keyed by `workdir + agent + session`; devices in the same scope
  share chat history, the resumable CLI session, and in-flight progress.
- Setup offers three network modes: no tunnel/direct public address, named
  Cloudflare Tunnel, and Cloudflare Quick Tunnel.
- App identity: bundle id / applicationId / namespace `dev.relay.app` (verify
  it is free on the Play Store before first publish), PM2 apps `relay-server` /
  `relay-tunnel`, SharedPreferences keys `relay.*.v1`, credential format
  `relay.credentials.v1` (files `*.relay.json/png`), env prefix `RELAY_*`,
  desktop binary `relay`.
- Offline push: Web Push (VAPID) for browsers, FCM for Android
  (Firebase project `relay-93917`). Both are optional and gated on config —
  see `server/.env.example` (`VAPID_*`, `FCM_SERVICE_ACCOUNT_FILE`) and
  `android/app/google-services.json`; the Gradle Google Services plugin is
  applied only when that JSON exists, so APKs build without Firebase config.

## Operating Principles

- Do not hard-code personal hosts, paths, tokens, or credentials.
- Mobile, Web, desktop, and backend platforms share the same API, credential,
  and session model; OS-specific setup stays in adapters and scripts.
- Keep README visitor-facing. Put manual startup, credential internals, API
  lists, build flow details, and agent handoff notes here. Architecture and
  coding guidance for agents lives in `docs/CLAUDE.md`.

## Manual Backend Setup

Prefer the platform setup scripts for real users. For manual agent work:

```bash
cd /path/to/Relay/server
npm install
cp .env.example .env
npm start
```

All environment variables are documented inline in `server/.env.example`. The
ones that most often matter for agent work:

```dotenv
PORT=8787
HOST=127.0.0.1
PUBLIC_BASE_URL=
RELAY_DEFAULT_DIR=
AGENT_TIMEOUT_MS=3600000
PROMPT_MAX_BYTES=        # prompt rides as one argv token; Linux caps ~128KB
CORS_ALLOW_ORIGIN=       # default *; narrow to the app origin in production
RELAY_FS_ROOTS=          # optional allowlist for the file API
USAGE_HTTP_TIMEOUT_MS=   # outbound quota requests, default 15s
```

`HOST=127.0.0.1` is the default for Cloudflare Tunnel and Quick Tunnel because
cloudflared reaches the backend locally. In Direct mode, use `HOST=0.0.0.0` so
the public IP/domain can reach the backend. `RELAY_DEFAULT_DIR` is only the
default path a brand-new device starts from (empty means `~/agent_deck`); each
device later stores its own current path locally and sends it through
`X-Workdir`. Work directories must be absolute paths.

## Credential QR Reference

The platform setup scripts generate the QR automatically. To regenerate it
manually from `server/`:

```bash
npm run credential
npm run credential -- --passphrase "pw"
npm run credential -- --passphrase "pw" --url "https://your-domain"
npm run credential -- --json-out "credentials/machine.relay.json"
```

The script creates `MACHINE_ID` if missing, adds a revocable per-device token to
`server/tokens.json`, prints the QR in the terminal, and saves
`server/credentials/<machine>.relay.png` plus
`server/credentials/<machine>.relay.json`. Upload/scan the PNG, or copy the JSON
file content into the app's paste-credential flow. The payload is encrypted with
PBKDF2-SHA256 (600k iterations) + AES-256-GCM; the plaintext password is never
written to disk.

Behavior notes:

- Auto-detects the current Quick Tunnel URL from logs, or uses
  `PUBLIC_BASE_URL` for named Cloudflare Tunnel / Direct mode unless `--url` is
  provided.
- Deletes old files under `server/credentials/` so the latest QR/paste payload
  is unambiguous, but does **not** revoke existing device tokens; use
  `--revoke` explicitly when disabling a device.
- Quick Tunnel credentials are tied to the current `trycloudflare.com` URL and
  must be regenerated after that URL changes.

Token management:

```bash
npm run credential -- --list-tokens
npm run credential -- --revoke <token-id>
```

## Flutter Client And Web Build

For local frontend development:

```bash
cd /path/to/Relay
flutter pub get
flutter run
```

Web credentials persist in browser local storage through Flutter's Web
secure-storage backend, so use a private browser profile for private machines.

To build the Web frontend and let the Node backend serve it:

```bash
flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn
cd server && npm start
```

When `build/web/index.html` exists, the backend serves the Flutter Web app on
the same host/port as the API. Both flags are load-bearing:
`--pwa-strategy=none` so browsers do not keep serving stale frontend code after
a backend restart, and `--no-web-resources-cdn` to bundle CanvasKit locally
(the gstatic CDN is unreachable on some networks and leaves the app
loaded-but-blank).

## APK Signing During Development

There is no release keystore yet. The Android `release` build type reuses the
debug signing config, so every APK currently built by this repo is debug-signed.
An APK built on one machine may not update an install signed by another
machine's `debug.keystore`; uninstall the old app first if needed:

```bash
adb uninstall dev.relay.app
```

Configure a proper release keystore before public or Play Store distribution.

## API Overview

All `/api/*` routes require `Authorization: Bearer <token>`. If the backend has
not generated any token yet, protected API routes return
`TOKEN_NOT_CONFIGURED` instead of running unauthenticated.

- Meta: `GET /api/health`, `GET /api/status`, `GET /api/diagnostics`,
  `GET /api/agents`, `GET /api/auth/status`, `GET /api/events` (SSE),
  `GET /api/tokens`, `POST /api/tokens/:id/revoke`
- Agent config: `GET /api/agent-options`, `GET`+`POST /api/agent-settings`,
  `GET /api/agent-version`, `POST /api/agent-update`
- Chat: `POST /api/chat` (SSE when `Accept: text/event-stream`),
  `POST /api/chat/cancel`, `GET /api/history`, `GET /api/history/export`,
  `GET /api/history/search`, `POST /api/session/clear`
- Sessions: `GET`+`POST /api/sessions`, `POST /api/sessions/active`,
  `POST /api/sessions/delete`
- Quota: `GET /api/usage`, `GET`+`POST /api/quota-schedules`,
  `POST /api/quota-schedules/cancel`
- Files & workdir: `GET`+`POST /api/workdir`, `GET /api/workdir/browse`,
  `GET /api/fs/download`, `POST /api/fs/upload`
- Push: `GET /api/push/config`, `POST /api/push/subscribe`,
  `POST /api/push/unsubscribe`, `POST /api/push/fcm/register`,
  `POST /api/push/fcm/unregister`
- Cards: `GET /api/cards`, `POST /api/cards/feedback`, `POST /api/cards/refresh`

## Environment / Ops Gotchas

- **PM2 God daemon restart RPC is broken on the current host**: `pm2 restart` /
  `pm2 reload` fail with "Process N not found" for every app, while reads
  (list/describe/save) work. Workaround that avoids touching unrelated apps:
  `pm2 delete relay-server && pm2 start ecosystem.config.js --only relay-server`
  then `pm2 save`. A full fix is `pm2 update`, but it cycles ALL apps — leave
  that to the user. `build_flow.sh`'s `pm2 restart` step fails until the daemon
  is repaired.
- **`server/ecosystem.config.js` `envValue()` reads `process.env` before
  `.env`**, and the long-lived PM2 daemon can hold stale values. When changing
  env vars, start/restart relay apps with the corrected values exported in the
  shell so `--update-env` injects them, then `pm2 save`.
- **Windows builds** have two toolchain quirks (non-ASCII project path breaks
  Flutter/MSBuild; VS 2026 MSVC rejects `flutter_local_notifications_windows`).
  See "Windows build gotchas" in `DESKTOP.md` for the workarounds.

## Code Integrity Passes

Two full manual audits (backend, then frontend) were run and **all findings
were fixed**; the per-finding audit documents have been retired. What remains
relevant:

### Backend (`server/`, audited 2026-06-09, fixed 2026-06-10, PR #4)

23 findings across performance / security / correctness / reuse, all resolved.
Durable outcomes:

- `server/lib/json-store.js`: cached atomic JSON store (tmp+rename, 0o600,
  in-memory cache invalidated on write) — use it for any new JSON state file
  instead of hand-rolling `loadAll`/`saveAll`.
- `server/lib/subscription-store.js` (shared Web Push / FCM subscription
  storage) and `server/lib/notify.js` (one call fans out to both push
  channels) — new notification kinds should go through `notify.js`.
- `server.js` was split into `server/routes/` (6 routers, see Project Shape).
- Security hardening: file API refuses sensitive paths (`server/tokens.json`,
  `.env`, `credentials/`, `~/.ssh`, CLI auth files) and honors the optional
  `RELAY_FS_ROOTS` allowlist; token comparison is timing-safe; credential KDF
  raised to PBKDF2 600k iterations; prompts are size-capped
  (`PROMPT_MAX_BYTES`) because they ride as a single argv token; uploads
  stream to a temp file instead of buffering in RAM; all outbound usage HTTP
  has timeouts (`USAGE_HTTP_TIMEOUT_MS`).
- Accepted trade-off: `chat-history*.json` stores raw unredacted content
  (file mode 0o600); redaction applies only to export/search.

### Frontend (`lib/`, audited 2026-06-10, fixed 2026-06-11)

16 findings across freeze / performance / security / reuse, all resolved
(15 code fixes + 1 accepted limitation). Durable outcomes:

- `lib/core/backend/api_transport.dart`: the single HTTP pipeline (stores,
  headers, error mapping) shared by `BackendClient` and `CardsService` — new
  API callers should reuse it, not copy the connection logic.
- Heavy work stays off the UI isolate: credential decrypt (PBKDF2 600k) runs
  in `compute()` on native (Web uses async WebCrypto); history responses
  >256KB are decoded in an isolate.
- The shared `/api/events` SSE stream has a 90s idle timeout (3× the server's
  30s heartbeat) so silently dead connections trigger the reconnect path; the
  chat POST stream keeps its own 65-minute timeout.
- Streaming deltas accumulate in per-request `StringBuffer`s and only
  materialize on the existing 80ms-throttled notify.
- `MachineCredentialsStore` / `DeviceIdStore` / `WorkdirStore` have **static**
  in-memory caches (multiple store instances exist across BackendClient,
  CardsService, and controllers). Any new write path in these stores must
  invalidate the cache (`_invalidateCache()`).
- Native file upload streams (`withReadStream` + `http.StreamedRequest`);
  Web upload keeps bytes (browser limitation).
- Shared utils to reuse instead of re-implementing:
  `lib/core/util/error_text.dart` (`friendlyErrorText` for user-facing
  errors), `lib/core/util/format_bytes.dart`, `time_format.dart`
  (`formatShortTime` / `formatLongTime`).
- Accepted limitation: Web file download buffers fully in memory
  (browser Blob requirement; bounded by the 300 MB download cap). Native
  downloads stream to disk.

## Build Flow

Use `./scripts/build_flow.sh` for the local full build flow:

1. Flutter dependency check, analysis, and tests.
2. Node syntax checks.
3. Web build and PM2 backend restart.
4. Android debug APK build and `adb install -r`.
