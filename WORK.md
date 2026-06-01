# WORK.md - Shared Agent Notes

This file is a short handoff log for agents working on AgentDeck. Keep it
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

## 2026-06-01 - Windows Backend Setup

- Added `backends/windows/` PowerShell scripts for setup, start, stop, status,
  and uninstall.
- Windows setup supports direct mode, named Cloudflare Tunnel, and Cloudflare
  Quick Tunnel, then generates the encrypted credential QR.
- Windows services run as background processes and are restored at login by a
  per-user Scheduled Task named `AgentDeck Backend`.

## 2026-05-31 - Named Cloudflare Tunnel Setup

- Linux `setup.sh` and macOS `backends/macos/setup.sh` now prompt for three
  network modes: direct/no tunnel, named Cloudflare Tunnel, or Quick Tunnel.
- Named Cloudflare Tunnel mode creates/reuses a tunnel, routes DNS, writes a
  local config under `server/cloudflared-config/`, and runs cloudflared under
  PM2/LaunchAgent.
- `server/ecosystem.config.js` reads `AGENTDECK_TUNNEL_MODE`,
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
  `server/credentials/<machine>.agentdeck.png` and
  `server/credentials/<machine>.agentdeck.json`.
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
