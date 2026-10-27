# Changelog

## Unreleased

### Changed

- Linux setup checks the Node.js version and, on Debian and Ubuntu, offers to
  install missing prerequisites with `sudo apt-get`: Node.js 24 from
  NodeSource, PM2, `zip`, the PTY build tools, and `cloudflared` for tunnel
  modes. Before, it stopped at the first missing tool, and accepted any
  Node.js version despite asking for 18 or newer. It refuses to run under
  `sudo`, which would make the backend and its files belong to root.

## 0.1.9 - 2026-10-26

### Added

- Cursor as a fifth agent, listed between Codex and OpenCode. It runs the host's
  `agent` CLI over ACP, signed in with the CLI's own `agent login` (or
  `CURSOR_API_KEY`). The model picker lists the account's Cursor models,
  defaulting to Auto, with each model's own effort levels and the Fast switch;
  permission tiers are Bypass (full auto), Plan only and Ask only. Each distinct
  model choice runs in its own Cursor process, so conversations on different
  models run at the same time. Relay's Cursor uses its own config directory,
  `server/cursor-config/`, so choices made in Relay never change the host's
  Cursor defaults. Quota Usage and the composer strip show Cursor's included
  usage.

### Changed

- ACP agents (OpenCode, Hermes, Cursor) start a new message after each tool
  call, as Claude Code and Codex do, instead of running the text on either side
  together.
- Relay answers ACP approval requests with "allow once" instead of "allow
  always", so Cursor no longer adds commands to the host user's own CLI
  allowlist.
- The model page lists main models first. Cursor models outside the plan's
  included usage, and older Claude Code and Codex models, move to a second
  page opened from the bottom of the screen. The Swarm form lists main models
  only.
- OpenCode's model list comes from the host's `opencode models`, so it stays
  current as OpenCode's free models change and includes every API provider
  configured in the host's OpenCode. Hermes gains a Model entry showing the
  model configured on the host.

### Fixed

- Failed or oversized uploads remove their temporary files before reporting an
  error, including when the upload fails before the temporary file opens.
- Claude Code no longer shows a false "log in again within a day" warning on
  Machine details. Relay reports no login deadline, because every supported CLI
  refreshes its own tokens.
- Deleting or clearing a Cursor conversation removes its session directory
  under `server/cursor-config/acp-sessions/`.
- The file API refuses Cursor's `auth.json`, like the Claude Code and Codex
  credential files.

## 0.1.8 - 2026-10-17

### Added

- A **What's new** entry on Home, above Tutorial, explaining each version's
  highlights in plain language, with smaller notes for other changes.
- A dedicated **Wallpaper** editor for one device-local image shared by all
  chats, with an explicit **Save** button, a smooth current-theme opacity slider,
  live preview, and loading indicators while images are imported and processed.
  Android, iOS and desktop keep the original image at full resolution in the
  app directory; the Web stores a compressed copy of up to 256 KiB.
  On the chat, home and Swarm pages everything over the wallpaper, including
  headers, banners and home cards, shares one readable acrylic tint; other pages
  show the wallpaper behind the same acrylic with solid content, and an empty
  chat shows only the wallpaper.
- Rename any session except Main from the drawer, keeping its history, position,
  and active selection, even during a running turn.
- Copy settled messages in solo chat. Edit your own messages to put their text
  back in the composer without changing history or sending automatically.
- Read-only file previews for the first 512 KiB of UTF-8 text, with syntax
  highlighting for supported code up to 20,000 characters.
- Attach files from the solo-chat **+** menu: upload to the workspace's
  `.relay/uploads/` directory and add their paths to the draft. The upload API
  accepts `mkdir=1` to create missing workdir-relative directories and parents.
- A context usage line above the solo-chat composer showing used tokens and
  the model's context window, with `?` for unknown values and remembered window
  sizes for new conversations.

### Changed

- **Update CLI** moved from the model and effort pages into the composer's
  **+** drawer, whose eight actions now sit in a 2x4 grid on every screen size.
- Android release APKs are signed with a dedicated release key instead of the
  debug key. Uninstall a previously installed Relay APK once before installing
  this version, then import the machine credential again.
- CI now builds the Web client and checks that the terminal's node-pty
  dependency loads, catching build and native dependency failures before release.

### Fixed

- Messages created within one clock tick now receive distinct IDs, avoiding
  message action and rendering mix-ups on Windows.
- A Claude reply started on its own no longer spins forever when a message
  sent meanwhile is folded into it, and Stop now stops such a reply. The folded
  answer appears once, under the message it answers.
- Compacting a conversation updates the context usage line right away, without
  waiting for the next reply.
- Backend installation allows node-pty's install scripts under npm 12; setup
  checks that the native terminal dependency loads instead of only checking its
  directory, with a rebuild fallback on Linux and macOS.
- File access restrictions now cover dot-suffixed copies of sensitive paths
  and resolved symlink destinations.
- Oversized directory downloads are refused as soon as the size scan exceeds
  the limit, without scanning the rest of the tree.
- CI syntax-checks every backend JavaScript file instead of only the first.

### Removed

- The deprecated agent command-line argument builder, superseded by live-session
  SDK and protocol settings, and the one-time scripts for renaming AgentDeck to
  Relay.

## 0.1.7 - 2026-10-02

### Added

- A Windows x64 backend release ZIP with Node.js, npm, locked production
  dependencies, and setup/service/credential command entry points. Agent CLIs
  are installed and authenticated separately on the host.
- Fenced code blocks in chat get syntax highlighting, a language label, and a
  copy button; inline code renders in the bundled monospace font instead of
  italics.
- The solo-chat composer pins the active agent's remaining Claude Code or Codex
  quota above the input, with a countdown to each window's reset. It refreshes
  when the agent changes and after each turn, at most once a minute per agent;
  tapping it opens the usage screen.
- A refresh button beside CLI agents in the drawer re-reads this device's
  workspace and reloads its sessions and conversation.

### Changed

- Agent replies in solo chat and Swarms are full-width panels headed by the
  agent's icon, name, and time, instead of 80%-wide bubbles. Execution steps
  render as a monospace timeline with the running step marked.
- The composer is full width on desktop and has separate + and send/stop
  buttons. + stays available during a turn, so model, effort, permission, and
  Fast mode can be changed at any time; clear and compact are disabled while a
  turn runs.
- The usage screen colours each quota by what remains (amber below 25%, red
  below 10%) and shows a countdown to each reset next to its reset time.
- The home page drops its repeated title, and the current machine card lines up
  with the other sections.
- One card style (lighter panel, hairline border, 12px corners) across the app,
  and shared status colours.
- Model, effort, permission, and Fast mode are now chosen per named session
  instead of per workdir/agent context. A new session starts from a copy of the
  current session's settings and is independent after that; existing sessions
  follow Main until their first change. Older clients that send no session id
  read and write Main's settings.

### Fixed

- Claude Code no longer answers "(claude produced no output)" after background
  subagents or monitors: a reply is matched to the message it answers, so the
  turns Claude runs on its own when background work finishes (or after a
  restart cut it off) can no longer end the user's turn early. A Claude process
  with background work still running is no longer closed as idle after 15
  minutes, which used to kill that work.
- Setting a new work path took effect only after the next event-stream
  heartbeat (up to 30 seconds), so the chat and drawer kept showing the previous
  workspace's conversation and sessions. Closing the event stream is now
  immediate, and the switch reloads at once.
- Selected text in your own chat bubble is now visible: the selection colour
  was the bubble's own fill colour.

## 0.1.6 - 2026-09-10

### Added

- SSH terminal key bar on Android and iOS with Ctrl, Shift, Esc, Tab, and the
  arrow keys a phone keyboard lacks. Ctrl and Shift latch for the next key,
  typed or tapped, then release, so Ctrl then `c` sends `^C`.

### Changed

- Remove the white exterior corners from the Relay icon and refresh Android,
  iOS, macOS, Web, and Windows icon assets.
- Expand the Chinese and English in-app getting-started and deployment guides
  with workspace, machine details, sessions, controls, and terminal workflows.

- A brand-new device now starts in `~/Relay` instead of `~/agent_deck`;
  `RELAY_DEFAULT_DIR` still overrides it.
- The chat header names the current workspace, with `Agent - Session` below it.
- The home page shows the current machine, the current workspace, up to three
  recent workspaces (from `GET /api/workdirs/recent`), and a Tutorial section,
  replacing recent swarms, agent sessions, and the Manage credentials shortcut.
- The drawer lists CLI agents above Swarm.
- Tapping the machine opens a Machine details page: Enter SSH and CLI agent
  status (both moved from Manage credentials), device tokens, then the backend
  status.
- File system: Set as work path is now the primary button, ahead of Upload file;
  swiping right on the file list goes up one folder.
- Usage query no longer opens on a full-screen spinner: the Claude Code and
  Codex cards show at once and each fills in as soon as its own quota answers
  (`GET /api/usage?source=claude|codex`), so a slow Codex probe no longer holds
  back Claude.

### Fixed

- Make workdir path assertions portable to Windows as well as Unix hosts.

- Codex authentication status now follows its app-server `account/read`
  contract on an explicit recheck, including managed ChatGPT, API-key, external
  token, and host-managed provider modes. Relay no longer treats the one-hour
  ID-token `exp` as a login deadline: managed ChatGPT credentials refresh
  automatically, and Codex shows no misleading expiry countdown. Transient
  verification failures also remain errors instead of being reported as a
  required login.

## 0.1.5 - 2026-08-19

### Removed

- Antigravity (`agy`) support. The CLI agent list is now Claude Code, Codex,
  OpenCode, and Hermes, and the usage screen reports Claude Code and Codex only.
  This drops the agy runner, BTW conversation cloning, model discovery, OAuth
  login, and the local language-server quota probe, along with
  `AGY_QUOTA_PROBE_TIMEOUT_MS`.
- The browser-only OAuth login mode (`authMode` / `requiresCode` on the login
  SSE stream), which existed solely for Antigravity. Every remaining OAuth agent
  now uses its own host-side login flow.
- BTW side conversations, for Claude Code and Codex alike. This drops the
  `/api/btw` routes, the side-scope session keys and their transcripts, the
  BTW button and dialog in the app, and the session-forking each agent needed
  to support them.
- The in-app OAuth login bridge for Claude Code and Codex. This drops the
  `/api/agent-auth/*` routes, the backend PTY that ran the CLI's own login
  command through `script -qfec`, and the login dialog in the app. Log in on
  the backend host, as OpenCode and Hermes already required.

### Added

- Swarm members can now summon each other. An `@mention` in a member's reply
  hands the floor to that teammate, so a round continues in waves instead of
  ending when the human's mentions are done; each wave snapshots the transcript
  again, so the newly summoned members see what was just said. Every member's
  prompt now lists its teammates and the `@name` that reaches each, because a
  member that does not know summoning works will never use it.
  `RELAY_SWARM_MAX_HOPS` bounds the agent-driven waves that follow one human
  message (default 3; 0 keeps summoning human-only), a member cannot summon
  itself, and a failed or cancelled turn summons no one. The transcript records
  which member summoned each reply.
- Credential expiry for Claude Code and Codex on the **Manage credentials**
  screen: the days left before the next login on the backend host, or the days
  since the credential expired. `/api/agents` reports it as
  `credentialExpiresAt`, read from the timestamps the two CLIs already store
  next to their tokens.

- The backend keeps Claude's five-hour quota window cycling with one minimal
  request whenever the window is idle, so its reset time is no longer reported
  as unknown after a lapse. The request can consume quota; set
  `ENABLE_CLAUDE_KEEPALIVE=false` to opt out.
- Linux service scripts (`start.sh`, `stop.sh`, `status.sh`, `uninstall.sh`)
  alongside the existing macOS and Windows sets.
- An MIT `LICENSE` and a GitHub Actions workflow running the analyzer and both
  test suites.
- Test coverage for the file API access policy, the device-token store, and
  quota schedules.

### Changed

- Reworked the English and Chinese READMEs into a visual product tour with
  Chromium screenshots captured against isolated demo data, a clearer system
  diagram, and a shorter path from project overview to backend setup.

- The composer's Model / Effort / Permission controls and the quota screens now
  open without waiting on the network. The option catalog describes the
  installed CLI, not the current workdir, so it is cached and the buttons render
  at their final size on the first frame instead of showing a spinner and then
  growing; returning from an option page adopts the selection it saved instead
  of refetching both the catalog and the settings. The usage and scheduler
  screens paint the last report immediately and refresh behind it.
- Backend option lookups no longer spawn processes on the hot path. Every
  `/api/agent-options`, `/api/agent-settings`, and agent turn re-located the CLI
  binary with a synchronous `command -v` subprocess and re-read
  `models-extra.json`, blocking the event loop (and so every SSE stream) for
  about 6 ms each, 12 ms for a settings read. Discovery now re-checks the binary
  at most once a minute, remembers hosts where a CLI is absent, and caches the
  extra-models file by mtime; a CLI update still busts the cache immediately.
  `describeAgent` went from 6.1 ms to 0.04 ms per call, `getSettings` from
  ~12 ms to 0.03 ms. `<cli> --version`, which ran on every model/effort page
  open, is cached the same way.
- Claude Code now runs as a persistent session instead of one process per turn.
  A chat keeps a single CLI process alive between messages, the way a terminal
  session does, so follow-up turns skip the cold start (roughly 3.1s to 1.5s in
  local measurement) and anything started in the background — watchers, servers,
  long-running tasks — is still running on the next turn instead of being killed
  the moment the turn ends. Cancelling a turn now interrupts it rather than
  killing the process, so the conversation survives a cancel.

  Live processes cost about 300 MB each, so an idle chat's process is closed
  after `RELAY_CLAUDE_IDLE_MS` (default 15 minutes) and at most
  `RELAY_CLAUDE_MAX_LIVE` (default 3) exist at once; a chat whose process was
  closed resumes into the same conversation on its next turn. `RELAY_CLAUDE_BIN`
  overrides which `claude` binary is driven.
- OpenCode, Hermes and Codex now run as persistent sessions too, over their
  stdio JSON-RPC servers — `acp` for the first two (Agent Client Protocol),
  `app-server` for Codex — with the same gains: follow-up turns skip the cold
  start (3.9s to 1.4s for opencode, 5.2s to 1.2s for hermes, 3.7s to 1.4s for
  codex in local measurement), and cancelling interrupts the turn instead of
  killing the conversation. Replies now stream token by token for opencode and
  hermes as well — the old opencode path could only stream whole JSON lines and
  hermes could not stream at all. OpenCode and Hermes apply settings over ACP;
  Codex applies most settings per turn, while a sandbox change reopens and
  resumes the thread without respawning the shared app-server process. No agent
  runs one process per turn any more.

  Unlike Claude, one process per agent hosts *every* chat for it, because these
  protocols give each session its own work tree. That pays the CLI's startup
  cost (~360 MB for opencode, ~90 MB for hermes) once instead of once per chat.
  Idle sessions are closed after `RELAY_AGENT_IDLE_MS` (default 15 minutes), at
  most `RELAY_AGENT_MAX_SESSIONS` (default 4) are live per agent, and the process
  exits with its last session; a chat whose session was closed reloads into the
  same conversation on its next turn.

  Approval prompts now reach Relay directly. Until there is an approval UI, the
  "Bypass" / "Auto-approve (yolo)" tiers approve them and the "Ask" / "Cautious"
  tiers refuse — deterministic, where the old non-interactive runs could stall.

  Background work started by a turn now outlives it for Claude, OpenCode and
  Hermes. Codex is the exception: its sandbox kills the process group of each
  command as that command returns, so background work there survives only if it
  detaches into its own session (`setsid`).
- Deleting or clearing a chat session now removes Relay history and its stored
  resume id, then requests CLI-side transcript deletion for all four agents.
  External CLI deletion remains best effort.
- `server/.env.example` documents the remaining supported settings, including
  the state-file overrides and the keepalive retry interval.
- The denylist that protects `tokens.json` now follows `RELAY_TOKENS_FILE`
  instead of assuming the default location.
- Documented that the credential generator also accepts a passphrase from
  `--passphrase` or `RELAY_CREDENTIAL_PASSPHRASE`.

### Fixed

- Chat-history search now jumps to the matched message reliably and highlights
  the search term after the destination conversation loads.

## 0.1.4 - 2026-07-13

### Added

- A resumable SSH terminal for mobile, Web, and desktop under **Manage
  credentials**, with one PTY per device credential, Light/Dark colors, and
  short-lived single-use WebSocket tickets.
- A Fast mode switch in the solo-chat composer for Claude Code and Codex. The
  setting defaults off and is shared by every named session in the same
  workdir/agent context.

### Changed

- Bundled a terminal monospace font for the Web SSH terminal so Chromium does
  not render excessive horizontal spacing between characters.
- Codex model and reasoning-effort choices now come from the installed CLI's
  structured catalog, including model-specific supported effort levels and
  defaults. Updating the CLI refreshes both choices without a Relay release.
- Consolidated contributor, deployment, and platform documentation around the
  current codebase; removed completed task specs, broken memory notes, duplicate
  platform pages, and roadmap-as-changelog copies.

### Fixed

- Removed false Codex model ids produced by binary string scanning and repaired
  stale or unsupported model/effort selections in solo chats and Swarms.
- CLI update failures are no longer reported as "Already up to date."
- Repaired the Linux setup entry after the one-command installer moved under
  `scripts/`.

## 0.1.3 - 2026-06-27

### Added

- First-run **Deploy backend** guide in the app, with Linux, macOS, and Windows
  setup commands and the same credential-import flow as the README.
- Background turn tracking for single-agent sessions, so long-running turns can
  continue while the user moves between sessions.
- Running-session indicators in the CLI agent drawer.
- Installed/authenticated/usable status for all five agents, selection gating,
  and in-app OAuth flows for Claude Code, Codex, and Antigravity on compatible
  backend hosts.
- More public-facing README structure, a dedicated security model, and release
  preparation documentation.

### Changed

- New-session creation no longer blocks just because another session is running.
- Credential import screens now surface scan, upload, and paste flows more
  clearly across mobile, Web, and desktop.
- Flutter and backend package metadata are bumped for the 0.1.3 release.

### Fixed

- Several chat/session state edges around switching sessions while work is still
  in progress.
- Documentation drift around production deployment and current version naming.

## 0.1.2 - 2026-06-20

- Added app screenshots and a more complete README.
- Added native agent icons and improved chat composer controls.
- Documented desktop build requirements and production deployment notes in the
  handbook.

## 0.1.0 - 2026-06-11

- First public baseline after the Relay rename.
- Hardened backend integrity, credential handling, route structure, and frontend
  state handling.
