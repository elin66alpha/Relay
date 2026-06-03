# WORK.md - Shared Agent Notes

This file is a short handoff log for agents working on Relay. Keep it
current, factual, and free of secrets. Detailed history lives in git.

## Current Project Shape

- Flutter client for Android, iOS, Web, and desktop runner projects.
- Node.js backend in `server/`; OS setup lives in `backends/` (Linux PM2,
  macOS LaunchAgent, Windows PowerShell/Scheduled Task).
- Supported CLI agents: Claude Code, Codex, and Antigravity (`agy`).
- Clients connect by importing an encrypted credential QR / payload and entering
  the user-chosen password.
- All protected APIs require a revocable bearer token from `server/tokens.json`.
- Sessions are keyed by `workdir + agent`; devices in the same path share chat
  history, the resumable CLI session, and in-flight progress.
- Setup offers three network modes: no tunnel/direct public address, named
  Cloudflare Tunnel, and Cloudflare Quick Tunnel.

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
