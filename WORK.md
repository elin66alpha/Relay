# WORK.md - Shared Agent Notes

This file is a short handoff log for agents working on AgentDeck. Keep it
current, factual, and free of secrets. Detailed history lives in git.

## Current Project Shape

- Flutter client for Android, iOS, Web, and desktop runner projects.
- Node.js backend in `server/`; OS setup lives in `backends/`.
- Supported CLI agents: Claude Code, Codex, and Antigravity (`agy`).
- Clients connect by importing an encrypted credential QR / payload and entering
  the user-chosen password.
- All protected APIs require a revocable bearer token from `server/tokens.json`.
- Sessions are keyed by `workdir + agent`; devices in the same path share chat
  history, the resumable CLI session, and in-flight progress.
- Cloudflare Quick Tunnel is the default trial networking mode. Direct public
  host mode is still available.

## 2026-05-31 - Web Performance and Documentation Cleanup [Uncommitted]

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

## 2026-05-31 - Credential JSON and Cloudflare Quick Tunnel [Uncommitted]

- `server/scripts/create-credential.js` generates both
  `server/credentials/<machine>.agentdeck.png` and
  `server/credentials/<machine>.agentdeck.json`.
- The JSON file is for paste import; credential files remain git-ignored.
- Credential creation auto-detects the current Cloudflare quick-tunnel URL from
  PM2 logs unless `--url` is passed.
- Generating a new credential removes old credential files, but does not revoke
  existing device tokens.

## 2026-05-31 - Shared Sessions by Workdir [Uncommitted]

- Backend session scope is `workdir + agent`, not `deviceId + agent`.
- Each client stores its current workdir locally and sends it with `X-Workdir`.
- History, resumable CLI session IDs, queues, cancellation, and SSE broadcasts
  are scoped by resolved workdir.
- Same-scope concurrent messages are serialized because the underlying CLI
  session is single-threaded.
- The client mirrors remote in-flight work by polling backend history snapshots
  when another device starts a turn in the same scope.

## 2026-05-31 - File Browsing and Workdir UI [Uncommitted]

- Work directory screen can browse folders upward/downward and hides dotfiles by
  default.
- File System screen can browse within the current workdir, upload files,
  download files, and download folders as zip archives.
- Web supports drag-and-drop upload.

## 2026-05-30 - Agent Markdown Rendering [Uncommitted]

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

