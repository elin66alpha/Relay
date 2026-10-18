# ENGINEERING.md

Engineering contract for this repository. Every agent reads this before any
change. Keep each section short; this file is the map, not the manual.
Operational detail lives in `AGENTS.md` and `docs/handbook.md`.

## Purpose

Relay lets one person drive Claude Code, Codex, OpenCode, and Hermes running on
their own machine from a Flutter client (mobile, Web, desktop) over an
authenticated HTTP/SSE backend.

## Scope

In:
- Solo chat per workdir + agent + session (max 8 sessions, Main undeletable), per-session agent controls.
- Swarms: multi-agent group chat with mention-driven waves (max hops `RELAY_SWARM_MAX_HOPS`).
- Filesystem browse/upload/download under a sensitive-path denylist.
- SSH-style PTY terminal via single-use WebSocket ticket.
- Quota/usage reporting, scheduled quota messages, keepalive; Web Push + FCM notifications.
- Linux/macOS/Windows backend install adapters; credential QR/file onboarding.

Out:
- Logging agents in from Relay. Reason: every credential is created on the host by the CLI itself.
- An approval UI for agent tool requests. Reason: approvals are answered from the configured permission tier.
- Per-turn agent process spawning. Reason: all agents run in pooled live sessions.

## Architecture

| Module | Responsibility | Interface | Depends on |
|---|---|---|---|
| server/server.js | config, middleware, auth, scope queue, SSE fan-out, route context, static Web | HTTP on PORT | lib/*, routes/* |
| server/routes/* | HTTP API per area (meta, push, fs, chat, group, sessions, quota, terminal) | factory(routeContext) -> express.Router | routeContext, some lib/* |
| server/lib/agents.js | process-runner boundary | runAgent(agent, prompt, onEvent, {workdir, settings, sessionKey}); onEvent receives progress, delta, segment, and `context` ({used, size}) events; purgeSession | session pools, agent-options |
| server/lib/claude-session-pool.js | Claude Agent SDK sessions per scope | pool send/forget/shutdown; send resolves {result, sessionId, stderr, context} | Agent SDK |
| server/lib/stdio-agent-pool.js (+acp-, codex-session-pool.js) | shared JSON-RPC stdio pool + drivers | pool API, driver | child_process |
| server/lib/model-discovery.js | locate each CLI and read its model catalog, cached for a minute (including "not installed") | discoverModels, clearModelDiscoveryCache | child_process |
| server/lib/agent-status.js, diagnostics.js | agent install/auth state from stored CLI auth files; GET /api/diagnostics report | getAgentStatuses, clearAgentStatusCache; buildDiagnostics | agents, tokens, workdir |
| server/lib/credential-file.js | encrypted relay.credentials.v1 payload for QR/file onboarding | encryptCredential | crypto |
| server/lib/agent-options.js / agent-settings.js | option validation and representation / persisted per-session settings | describeAgent, normalizeSettings, getSettings/setSettings | model-discovery, json-store |
| server/lib/agent-turn.js / group-turn.js | one solo turn / Swarm prompt building | runAgentTurn, responders | agents |
| server/lib/context-windows.js | last context window size each agent + model reported, so a conversation without a reply can still show its limit | recordContextWindow(agent, model, size), contextWindowFor(agent, model); GET /api/history returns it as `contextWindow` | json-store |
| server/lib/history.js, chat-sessions.js, groups.js, tokens.js | persistence | per-module load/save | json-store (history: own async writer) |
| server/lib/filesystem.js, workdir.js | path policy | resolve/list/prepare | tokens |
| server/lib/usage.js, quota-*.js | quota reporting, schedules, keepalive | buildUsageReport, schedule API | json-store |
| server/lib/notify.js, push.js, fcm.js | notifications | notifyAll | subscription-store |
| server/lib/terminal-manager.js | resumable PTY per token | createTerminalManager | node-pty |
| lib/core/backend | authenticated transport, SSE codec, API client | ApiTransport, BackendClient | http |
| lib/core/{models,storage,credentials,notifications,platform,widgets,i18n,theme,util,settings,download} | data models, cached stores, credential decode, platform adapters, shared widgets (agent icon, code block, wallpaper and acrylic surfaces), strings, theme and status colours, helpers, app settings and one device-local wallpaper (original file on native, bounded inline copy on Web), download progress | classes; AppSettingsController wallpaper/saveWallpaper; platform prepareWallpaper/storeWallpaperImage/loadWallpaperImage | core only |
| lib/features/chat | app shell: solo chat, Swarm, and the drawer that opens every other screen | BotChatController, GroupChatController, screens | other lib/features, lib/core |
| lib/features/quota | quota state (QuotaController, one instance created in main.dart and shared by the strip, usage and scheduler screens) and its screens | QuotaController, screens | lib/core |
| lib/features/{cli_agents,filesystem,machines,settings,ssh} | screens + controllers per area; take BackendClient and callbacks, never BotChatController | widgets | lib/core (machines also cli_agents, ssh) |
| backends/{linux,macos,windows} | install/service adapters | setup/start/stop/status/uninstall | scripts/setup.sh, PM2/launchd/Windows |

Dependency direction: server routes -> lib -> json-store; lib/features/chat -> other lib/features -> lib/core. Nothing outside lib/features/chat imports it, the other features import each other without cycles, and lib/core imports no feature.

## Features

| Feature | Module | Status |
|---|---|---|
| Solo chat + sessions | routes/chat, routes/sessions, agent-turn, features/chat | active |
| Session rename (every session except Main) | routes/sessions, chat-sessions, features/chat drawer | active |
| Message Copy (all settled replies) and Edit (user messages: text back into the composer, nothing rewritten) | features/chat | active |
| Per-session agent controls (model/effort/permission/fast) | agent-options, agent-settings, chat/agent_controls | active |
| Background Claude turns | claude-session-pool, server.js backgroundTurnHandler | active |
| Conversation context usage (used / window above the composer) | session pools, agents, agent-turn, context-windows, routes/chat, chat/context_meter | active |
| Swarms | routes/group, groups, group-turn, chat/group_chat_* | active |
| Filesystem | routes/fs, filesystem, features/filesystem | active |
| File preview (read-only, first 512 KiB of UTF-8 text, highlighted) | features/filesystem, core/widgets/code_block | active |
| Chat attachments (upload to `<workdir>/.relay/uploads/`, path appended to the draft; upload `mkdir=1` for workdir-relative paths) | routes/fs, filesystem, core/backend, features/chat | active |
| SSH terminal | routes/terminal, terminal-manager, features/ssh | active |
| Quota + schedules + keepalive | usage, quota-*, features/quota | active |
| Notifications (Web Push, FCM) | notify, push, fcm, core/notifications | active |
| Device-local shared wallpaper (explicit Save, one live opacity slider for the current theme, centered cover; first-level pages (chat, home, Swarm) make every surface on the wallpaper acrylic; other pushed pages show it behind a full-page acrylic layer with solid content) | core/settings, core/widgets, features/settings, features/chat | active |
| What's new (Home entry above Tutorial; per release 1-3 plain-language highlights plus other changes in small text) | features/settings/whats_new_screen, features/chat home | active |
| Credential onboarding | scripts/create-credential, core/credentials, features/machines | active |
| Update check (Settings → Check for updates compares with the latest GitHub release and only reports it; no download) | features/settings | active |

Deprecated features stay listed until their code is deleted, then the row is
removed.

## Verification

- `flutter analyze --no-pub` -> "No issues found!"
- `flutter test --no-pub` -> "All tests passed!"
- Settings → Wallpaper: choosing/removing an image and moving the single current-theme opacity slider updates the preview before Save; Save commits one shared image and both theme values; on native the original file appears under the app support `wallpaper/` directory and the previous copy is deleted. Import/processing shows a spinner. Agent switches keep the same image. With an image, chat chrome and both message bubbles use one 72% tint, clipped to their boundaries, and on chat, home and Swarm the header, banners, home cards and drawer machine tile are acrylic too, the composer surface reaches the screen bottom behind the gesture bar; every other pushed page (File System, Quota Usage, Settings, ...) shows the blurred wallpaper under a 72% tint with solid content. An empty chat with an image shows no agent icon or "Start chatting" text. Removing the image restores solid surfaces and that placeholder.
- `(cd server && git ls-files '*.js' | xargs -r -n1 node --check)` -> exit 0
- `npm --prefix server test` -> "# fail 0"
- `(cd server && node -e "require('node-pty')")` -> exit 0
- `flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn` -> exit 0, `build/web/index.html` exists
- `flutter build apk --release --no-pub` -> fails naming `android/key.properties` when it is missing; with it, `apksigner verify --print-certs` on the APK shows SHA-256 `3e4dea3f…720f`
- Home: a What's new section sits above Tutorial; its entry shows the newest version and highlight names and opens a page listing 1-3 highlights per release with other changes in small text, in English and Chinese.
- Drawer: every session except Main has a rename button; a new name shows in the list and the chat header without changing the active session.
- Solo chat: a settled message shows Copy; a user message also shows Edit, which puts its text in the composer and sends nothing.
- File browser: tapping a UTF-8 text file shows its contents; a file containing a NUL byte shows "Cannot preview this file."; past 512 KiB it shows "Only the first 512 KiB is shown."
- Solo chat + → Attach file: the file appears as `<workdir>/.relay/uploads/<yyyyMMdd-HHmmss>-<name>` and its relative path is appended to the draft, nothing sent.
- Settings → Check for updates: on the latest version it shows "You are on the latest version, <version>"; when GitHub's latest release tag is higher it shows "Version <tag> is available on GitHub Releases"; offline it shows "Could not check for updates. Try again later."
- `grep -rn "import '\.\./chat/\|features/chat/" lib/features --include=*.dart | grep -v '^lib/features/chat/'` -> no output
- `grep -rn "features/" lib/core --include=*.dart` -> no output
- After a reply in solo chat with any of the four agents, the line above the composer shows `<used> / <window>` (e.g. `42k / 200k`) at its right end. A new or cleared conversation shows `0 / <window>`; a conversation whose replies predate the feature shows `? / <window>`; `<window>` reads `?` until that agent + model has replied once.

## Milestones

| Milestone | Completion criteria | Status |
|---|---|---|
| 0.1.7 | four version locations read 0.1.7; CHANGELOG has 0.1.7 entry | done |
| 0.1.8 | four version locations read 0.1.8; CHANGELOG and What's new have 0.1.8 entries | done |

## Changes

Architecture-level changes only. Keep the latest 10; fold older entries into
one summary line.

- 2026-06-10: server routes split out of server.js into server/routes. Reason: server.js exceeded 2000 lines.
- 2026-10-02: agent controls persisted per workdir + agent + session. Reason: sessions need independent settings.
- 2026-10-17: feature dependencies made acyclic: the drawer moved into features/chat, quota state moved from BotChatController to features/quota QuotaController, non-chat features take BackendClient and callbacks. Reason: features/* imported BotChatController and formed three cycles.
- 2026-10-17: code_block.dart moved from features/chat to core/widgets. Reason: the file preview reuses it, and features must not import each other.
- 2026-10-17: added server/lib/context-windows.js (state file context-windows.json). Reason: no CLI exposes a model's context window before a reply, so the last reported size per agent + model is remembered.

## Review

Last review: 2026-10-17
Features since last review: 3
Last result: Intent Problem, Structure Problem, Entropy Problem, Test value Problem, Documentation Problem, Operability Problem, Evolution Problem, Performance Problem; 13 findings (F1-F13 in the second 2026-10-17 audit), all addressed on 2026-10-17.

## Deviations

- [open] 2026-10-17: history.js and usage.js keep their own JSON writers instead of json-store. Reason: history needs debounced async writes; usage has none.
- [closed] 2026-10-17: features/* import features/chat/bot_chat_controller (reverse edges). Reason: none given; BotChatController predates the split. Closed 2026-10-17: no feature outside chat imports it.
