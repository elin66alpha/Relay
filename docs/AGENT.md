# AGENT.md - Shared Agent Notes

This file is a short handoff log and technical reference for agents working on
Relay. Keep it current, factual, and free of secrets. Detailed history lives in
git.

## Current Project Shape

- Flutter client for Android, iOS, Web, and desktop runner projects.
- Node.js backend in `server/`; OS setup lives in `backends/` (Linux PM2,
  macOS LaunchAgent, Windows PowerShell/Scheduled Task).
- Supported CLI agents: Claude Code, Codex, and Antigravity (`agy`).
- Clients connect by importing an encrypted credential QR / payload and entering
  the user-chosen password.
- All protected APIs require a revocable bearer token from `server/tokens.json`.
- Sessions are keyed by `workdir + agent + session`; devices in the same scope
  share chat history, the resumable CLI session, and in-flight progress.
- Setup offers three network modes: no tunnel/direct public address, named
  Cloudflare Tunnel, and Cloudflare Quick Tunnel.

## Operating Principles

- Do not hard-code personal hosts, paths, tokens, or credentials.
- Mobile, Web, desktop, and backend platforms share the same API, credential,
  and session model; OS-specific setup stays in adapters and scripts.
- Protected backend APIs require a revocable device token generated through the
  encrypted credential QR.
- Setup offers direct public-host mode, named Cloudflare Tunnel for stable
  hostnames, and Cloudflare Quick Tunnel for fast trials.
- Keep README visitor-facing. Put manual startup, credential internals, API
  lists, build flow details, and agent handoff notes here.

## Manual Backend Setup

Prefer the platform setup scripts for real users. For manual agent work:

```bash
cd /path/to/Relay/server
npm install
cp .env.example .env
npm start
```

Important environment variables:

```dotenv
PORT=8787
HOST=127.0.0.1
MACHINE_ID=
MACHINE_NAME=
PUBLIC_BASE_URL=
RELAY_TUNNEL_MODE=
CLOUDFLARED_BIN=
CLOUDFLARED_ARGS=
RELAY_DEFAULT_DIR=
AGENT_TIMEOUT_MS=3600000
POWERSHELL_BIN=
ENABLE_QUOTA_WATCH=true
QUOTA_POLL_MS=300000
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
file content into the app's paste-credential flow. Generating a new QR removes
old credential files, but does not revoke existing device tokens. The payload is
encrypted with PBKDF2-SHA256 + AES-256-GCM; the plaintext password is never
written to disk.

Credential script behavior:

- Auto-detects the current Quick Tunnel URL from logs, or uses
  `PUBLIC_BASE_URL` for named Cloudflare Tunnel / Direct mode unless `--url` is
  provided.
- Creates and persists `MACHINE_ID` in `.env` when missing.
- Creates one revocable token per generated credential payload.
- Deletes old files under `server/credentials/` so the latest QR/paste payload
  is unambiguous.
- Does not revoke existing device tokens when generating a new QR; use
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
cd /path/to/Relay
flutter build web --pwa-strategy=none
cd server
npm start
```

When `build/web/index.html` exists, the backend serves the Flutter Web app on
the same host/port as the API. Use `--pwa-strategy=none` so browsers do not keep
serving stale frontend code after a backend restart.

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

- `GET /api/health`
- `GET /api/status`
- `GET /api/diagnostics`
- `GET /api/agents`
- `GET /api/auth/status`
- `GET /api/usage`
- `GET /api/quota-schedules`
- `POST /api/quota-schedules`
- `POST /api/quota-schedules/cancel`
- `GET /api/workdir`
- `GET /api/workdir/browse`
- `POST /api/workdir`
- `GET /api/fs/download`
- `POST /api/fs/upload`
- `POST /api/chat`
- `POST /api/chat/cancel`
- `GET /api/sessions`
- `POST /api/sessions`
- `POST /api/sessions/active`
- `POST /api/sessions/delete`
- `GET /api/history`
- `POST /api/session/clear`
- `GET /api/events`

## 2026-06-03 - Per-agent Model / Effort / Permission controls

- New composer "+" drawer controls let the user pick, per chat, the agent's
  model, reasoning effort, and permission mode. Capability-aware: agy exposes no
  model/effort in its CLI, so only Permission shows for it; Claude and Codex show
  all three.
- Single source of truth: `server/lib/agent-options.js` maps every option to the
  exact CLI argv. `buildArgs(agentKey, settings)` is spliced into each spawn in
  `agents.js`. **Defaults reproduce the old always-bypass / no-model / no-effort
  behavior**, so unconfigured scopes are byte-for-byte unchanged. Flag specifics:
  Claude `--model` / `--effort` (native, low|medium|high|xhigh|max) /
  `--permission-mode`; Codex `-m` / `-c model_reasoning_effort=` / permission via
  `-c sandbox_mode=` + `-c approval_policy=never` (NOT `-s` — `codex exec resume`
  rejects it; and exec is non-interactive so approvals must be `never` or it
  hangs); agy permission only (`--dangerously-skip-permissions` vs `--sandbox`).
- Selections persist per `workdir + agent` in `agent-settings.json` (gitignored),
  shared across devices in the scope. server.js loads them at spawn time for both
  live chat and scheduled messages.
- Endpoints (all bearer-protected): `GET /api/agent-options`, `GET`+`POST
  /api/agent-settings`, `GET /api/agent-version`, `POST /api/agent-update`. The
  update endpoint runs `<cli> update` so a user who doesn't see the newest model
  can pull it in from the model picker's "Update CLI" button (confirm + version
  echo). Brand-new pinned models can be added with no code change via
  `server/models-extra.json` (gitignored).
- Client: `lib/features/chat/agent_controls.dart` (controls row + option sheet),
  `lib/core/models/agent_options.dart`, new BackendClient methods, l10n strings.
- Verified: flutter analyze clean, flutter test passes, node --check green, the
  built flag combos accepted live by `claude` and `codex`, endpoints round-trip
  on localhost, web rebuilt + served (200, <title>Relay</title>), debug APK
  installed.
- ENVIRONMENT GOTCHA (not caused by this work): the host PM2 God daemon's
  restart/reload action RPC is broken — `pm2 restart`/`reload` fail with
  "Process N not found" for EVERY app (old id 2 and a fresh id 4 alike) while
  reads (list/describe/save) work. Workaround used to load new server code
  without touching the unrelated `claude-discord` / `claude-quota-watch` apps:
  `pm2 delete relay-server && pm2 start ecosystem.config.js --only relay-server`
  (delete/start use different RPCs that still work), then `pm2 save`. A full fix
  is `pm2 update` (respawns the daemon) but it cycles ALL apps, so leave that to
  the user. `build_flow.sh`'s `pm2 restart` step will fail until the daemon is
  repaired.

## 2026-06-04 - Windows native Flutter frontend pass

- Desktop chat shell now treats wide Windows/macOS/Linux layouts as a native
  tool surface: permanent left sidebar fills the window height, the active
  agent/session header sits in the main pane, composer width is capped on wide
  monitors, and desktop/Web Enter sends while Shift+Enter still inserts a
  newline through the text field.
- Windows local notifications are initialized through
  `flutter_local_notifications` with a Relay AppUserModelID, while init/show
  failures degrade to the existing in-app fallback instead of blocking startup.
- Windows runner starts at 1360x860 and enforces a 900x640 minimum logical
  window size so desktop controls do not collapse into unusable layouts.
- Secondary screens were desktop-constrained: settings, credentials, quota
  usage, quota scheduler, file system, and Card Mode now use centered content
  widths or mouse-friendly action buttons where appropriate.
- **Windows release build verified** (`flutter build windows --release` →
  `build/windows/x64/runner/Release/relay.exe`, ~792 KB + `flutter_windows.dll`
  + plugin DLLs + `data/`). `dart analyze` is clean and `flutter test` is green.
  The app launches and most features work in manual smoke testing. Two
  environment workarounds were required to compile — see "Windows build
  gotchas" in `DESKTOP.md`:
  1. **Non-ASCII project path breaks the Flutter/MSBuild toolchain.** When the
     repo lives under a path with CJK characters, `flutter analyze` crashes in
     the LSP channel and `flutter build windows` fails reading `app.dill` (the
     path is mangled through the ANSI code page). Build from an ASCII-only path,
     or use `dart analyze` (not `flutter analyze`) for static checks.
  2. **VS 2026's MSVC 14.51 rejects `flutter_local_notifications_windows`.**
     The plugin still includes `<experimental/coroutine>`, which the newest STL
     turns into a hard error (`STL1011` / `C2338`). Set
     `CL=/D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` in the build
     environment to compile. A permanent fix is to add that define to the
     plugin target in CMake or update the plugin once upstream migrates to
     `<coroutine>`.

## 2026-06-02 - Rebrand AgentDeck -> Relay (clean public identity)

- Full rebrand for public release. Two passes, both via scripted
  case-sensitive/ordered `sed` over `git ls-files` (so node_modules/, build/, and
  gitignored secrets are untouched): `scripts/rename_to_relay.sh` swept the
  PascalCase brand `AgentDeck -> Relay` (display text + docs only), then
  `scripts/migrate_identity_to_relay.sh` migrated every functional identifier off
  the old brand.
- New app identity: bundle id / applicationId / namespace `dev.agentdeck.app ->
  dev.relay.app` (chosen to mirror the old `dev.*.app` shape; verify it's free on
  the Play Store before first publish). The kotlin
  source dir moved `dev/agentdeck/app/ -> dev/relay/app/`; the download
  `MethodChannel` (Kotlin + `file_saver_stub.dart`) tracks it. iOS/macOS/Linux
  bundle ids, macOS LaunchAgent labels (`dev.relay.app.backend/.tunnel`), and
  copyright/company strings updated too.
- Other identifiers (all consistent across their paired sites): Dart package
  `agentdeck -> relay` (only `package:` user was the codec test; lib/ uses
  relative imports), PM2 names `relay-server`/`relay-tunnel`, SharedPreferences
  keys `relay.*.v1`, credential format `relay.credentials.v1` + file ext
  `*.relay.json/png`, env vars `RELAY_*`, web-push JS global `window.relayPush`
  (interop JS + `@JS` annotations), FCM Firebase app name `relay-fcm` +
  `relayFcmBackgroundHandler`, desktop binary `relay`.
- Verified: `flutter analyze` clean, credential codec test passes (after
  `flutter pub get` rebuilt the package graph for the new name), `node --check`
  green on backend.
- CUTOVER DONE (2026-06-03): a fresh Firebase project `relay-93917` was created;
  `android/app/google-services.json` (package `dev.relay.app`) and the backend
  service account `server/fcm-service-account.json` are in place (both gitignored),
  with `FCM_SERVICE_ACCOUNT_FILE` pointing at the latter. PM2 was re-registered as
  `relay-server` / `relay-tunnel` (the unrelated `claude-*` apps were left
  running). Web + debug APK were rebuilt — note `flutter clean` was required first,
  because the cached web entrypoint still imported `package:agentdeck/main.dart`.
  The credential was regenerated and re-imported; FCM offline push was verified
  end-to-end on the `dev.relay.app` build (stale old-project tokens self-prune with
  a `SenderId mismatch`).
- PM2 gotcha learned here: `server/ecosystem.config.js` `envValue()` reads
  `process.env` before `.env`, and the long-lived PM2 daemon had stale
  `CLOUDFLARED_ARGS` / `FCM_SERVICE_ACCOUNT_FILE` from the old names. Start/restart
  relay apps with the corrected values exported in the shell (or inline before
  `build_flow.sh`) so `--update-env` injects them; `pm2 save` then persists a
  correct dump for reboots without needing a daemon `pm2 kill`.

## 2026-06-02 - FCM Android offline push

- Added Firebase Cloud Messaging as the native offline push path for Android
  quota-reset and scheduled-message alerts. It mirrors Web Push scoping:
  `quota_reset` reaches all registered devices, while `quota_schedule_sent`
  targets devices registered under the schedule's `workdir`; each token stores
  its language for English/Chinese message bodies.
- FCM is gated everywhere. APKs build without Firebase config because
  `com.google.gms.google-services` is applied only when
  `android/app/google-services.json` exists; web/desktop use no-op Dart stubs
  and do not initialize Firebase.
- To activate FCM, drop the Android app config at
  `android/app/google-services.json`, put a backend service account JSON on the
  host (for example `server/fcm-service-account.json`), and set
  `FCM_SERVICE_ACCOUNT_FILE=/absolute/path/to/server/fcm-service-account.json`
  in `server/.env`. The service account and runtime token store
  (`server/fcm-tokens.json`) are gitignored.

## 2026-06-01 - Scheduled messages moved to a dedicated screen

- Scheduling left the usage dialog and became its own left-drawer entry →
  `lib/features/quota/quota_scheduler_screen.dart`: one row per claude/codex with
  the agent name, its next 5-hour reset time, a message box, **Send**, and a
  **Clear** button (only when a schedule is queued). The usage dialog is now
  read-only (quota numbers + reset times). Cross-device: it re-syncs from
  `quota_schedule_*` SSE events and preserves an unsent local draft on remote
  sync (`_syncControllers`).
- Pending uniqueness is now **per source per workdir** (each workspace keeps its
  own pending draft); Send uses `replaceExisting: true` to overwrite in place
  instead of hitting `409`. Note: since a reset is host-wide, all of a source's
  per-workdir schedules fire on the same reset (intended trade-off).
- Schedule events refetch only the schedule list, not `/api/usage` (quota
  numbers don't change on a schedule edit), so the screen avoids the external
  usage call on every save/event. `server/lib/usage.js` also parallelizes the
  Claude+Codex providers and caches Claude usage for 60s.

## 2026-06-01 - Multi-session, diagnostics, and scheduled quota messages

- Named chat sessions per `workdir + agent`: scope key is now
  `workdir\0agent\0sessionId`; the default `Main` session reuses the legacy
  context key (no history migration). Capped at 8 sessions per context; `Main`
  cannot be deleted (`server/lib/chat-sessions.js`, `cli_agents_drawer.dart`).
- `GET /api/diagnostics` (`server/lib/diagnostics.js`) backs a fuller machine
  status dialog: listener, public URL, token counts, CLI availability/login,
  workdir access, storage files, web build, and live request/queue/SSE counts.
- Scheduled quota messages (`server/lib/quota-schedules.js`): draft a message and
  the watcher auto-sends it after the next 5-hour reset for that source.
  (Entry point later moved to a dedicated screen — see the newer entry above.)
  Hardening applied here — one pending schedule per source+workdir
  (`409 SCHEDULE_EXISTS`), interrupted `running` schedules are reconciled to
  `failed` on startup, and the JSON store prunes finished records to
  `MAX_FINISHED` (50). `quota-schedules.json` is secret/gitignored.

## 2026-06-01 - Unified File System, Downloads, and Cleanup

- The Work directory screen was merged into the **File system** screen. One
  drawer entry now browses by absolute path (up to filesystem root), sets the
  work path via **Set as work path**, and uploads/downloads. The old
  `work_directory_screen.dart` was removed.
- Downloads stream with a progress bar driven by an app-level `DownloadManager`
  so progress and the completion notification survive leaving the screen. Files
  save to the system Downloads folder with no picker (Android via a MediaStore
  platform channel; desktop via `getDownloadsDirectory`; the browser folder on
  Web) and the save location is shown on screen.
- Size caps: a download is rejected above 300 MB (a folder by its uncompressed
  total, `DOWNLOAD_MAX_BYTES`); a single upload above 100 MB (`UPLOAD_MAX_BYTES`),
  pre-checked in the app and enforced on the server.
- Removed dead code now that the screens merged: routes `/api/fs/list`,
  `/api/workdir/check`, `/api/workdir/reset`; backend client `listFiles`,
  `checkWorkdir`, `resetWorkdir`; `listDirectory` in `server/lib/filesystem.js`;
  and several unused i18n strings. Docs realigned to the merged screen and the
  current API surface.

## 2026-06-01 - Windows Backend Setup

- Added `backends/windows/` PowerShell scripts for setup, start, stop, status,
  and uninstall.
- Windows setup supports direct mode, named Cloudflare Tunnel, and Cloudflare
  Quick Tunnel, then generates the encrypted credential QR.
- Windows services run as background processes and are restored at login by a
  per-user Scheduled Task named `Relay Backend`.

## 2026-05-31 - Named Cloudflare Tunnel Setup

- Linux `setup.sh` and macOS `backends/macos/setup.sh` now prompt for three
  network modes: direct/no tunnel, named Cloudflare Tunnel, or Quick Tunnel.
- Named Cloudflare Tunnel mode creates/reuses a tunnel, routes DNS, writes a
  local config under `server/cloudflared-config/`, and runs cloudflared under
  PM2/LaunchAgent.
- `server/ecosystem.config.js` reads `RELAY_TUNNEL_MODE`,
  `CLOUDFLARED_BIN`, and `CLOUDFLARED_ARGS` from `.env` so PM2 can omit the
  tunnel app, run named tunnel args, or run Quick Tunnel args.
- `server/scripts/create-credential.js` prefers stable `PUBLIC_BASE_URL` for
  named/direct mode, then falls back to Quick Tunnel log detection.

## 2026-05-31 - Web Performance and Documentation Cleanup

- Throttled high-frequency streaming assistant updates in
  `lib/features/chat/bot_chat_controller.dart` to reduce Web rebuild pressure.
- Assistant bubbles render lightweight plain text while a reply is streaming,
  then render Markdown after the response is finalized. Final formatting is
  unchanged.
- Chat screen now reads the message list once per build and uses stable message
  keys.
- Card Mode swipe animations no longer call `setState` on the whole page every
  animation frame.
- README and ROADMAP files were tightened and updated to match the current
  shared-session model.
- Removed the old Card Mode implementation prompt document.

## 2026-05-31 - Credential JSON and Cloudflare Quick Tunnel

- `server/scripts/create-credential.js` generates both
  `server/credentials/<machine>.relay.png` and
  `server/credentials/<machine>.relay.json`.
- The JSON file is for paste import; credential files remain git-ignored.
- Credential creation auto-detects the current Cloudflare quick-tunnel URL from
  PM2 logs unless `--url` is passed.
- Generating a new credential removes old credential files, but does not revoke
  existing device tokens.

## 2026-05-31 - Shared Sessions by Workdir

- Backend session scope is `workdir + agent`, not `deviceId + agent`.
- Each client stores its current workdir locally and sends it with `X-Workdir`.
- History, resumable CLI session IDs, queues, cancellation, and SSE broadcasts
  are scoped by resolved workdir.
- Same-scope concurrent messages are serialized because the underlying CLI
  session is single-threaded.
- The client mirrors remote in-flight work by polling backend history snapshots
  when another device starts a turn in the same scope.

## 2026-05-31 - File Browsing and Workdir UI

- Work directory screen can browse folders upward/downward and hides dotfiles by
  default.
- File System screen can browse within the current workdir, upload files,
  download files, and download folders as zip archives.
- Web supports drag-and-drop upload.

## 2026-05-30 - Agent Markdown Rendering

- Assistant chat bubbles render Markdown for headings, emphasis, lists, quotes,
  code blocks, and dividers.
- User messages remain plain text.
- CLI shorthand such as `###Title`, unclosed leading `**Title`, and legacy
  `##text##` is normalized outside fenced code blocks.

## Build Flow

Use `./scripts/build_flow.sh` for the local full build flow:

1. Flutter dependency check, analysis, and tests.
2. Node syntax checks.
3. Web build and PM2 backend restart.
4. Android debug APK build and `adb install -r`.
