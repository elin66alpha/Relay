# ENGINEERING.md

Engineering contract for this repository. Every agent reads this before any
change. Keep each section short; this file is the map, not the manual.
Contributor rules live in `AGENTS.md`; operational detail lives in `docs/handbook.md`.

## Purpose

Relay lets one person drive Claude Code, Codex, Cursor, OpenCode, and Hermes
running on their own machine from a Flutter client (mobile, Web, desktop) over
an authenticated HTTP/SSE backend.

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

Top-level layout. The client is `app/` and the backend is `server/`; every
script is under `scripts/` except the Node tools in `server/scripts/`.

| Directory | Holds |
|---|---|
| app/core | the `relay_core` Dart package: every screen, controller, test and asset (`lib/`, `test/`, `assets/`) |
| app/shell | the runnable Flutter app `relay`: `main.dart`, the app version, and the android, ios, linux, macos, windows and web platform projects |
| server | the Node.js backend, its tests, its Node tools (`scripts/`) and, on a deployed host, its generated state |
| scripts/install/{linux,macos,windows} | what users run to install and manage a backend |
| scripts/release | release bundle builders, version/documentation checks, Windows setup checks and local Android signing for a release draft |
| scripts/dev | local development helpers (build flow, backend restart, icon export) |
| docs | handbook, install guides, security model, changelog, release notes, README screenshots |
| .github/workflows | CI on pull requests, an on-demand unsigned iOS IPA, and a manually prepared release draft |

| Module | Responsibility | Interface | Depends on |
|---|---|---|---|
| server/server.js | config, middleware, auth, scope queue, SSE fan-out, workdir presence, route context wiring, static Web; holds no feature logic | HTTP on PORT | lib/*, routes/* |
| server/routes/* | HTTP API per area (meta, push, fs, chat, group, sessions, quota, terminal); group.js also orchestrates Swarm waves | factory(routeContext) -> express.Router | routeContext for anything with state or I/O; Node built-ins and argument-only lib/* helpers required directly |
| server/lib/agents.js | process-runner boundary | runAgent(agent, prompt, onEvent, {workdir, settings, sessionKey}); onEvent receives progress, delta, segment, and `context` ({used, size}) events; purgeSession | session pools, agent-options, model-discovery, cli-paths, json-store, workdir |
| server/lib/claude-session-pool.js | Claude Agent SDK sessions per scope | pool send/forget/shutdown; send resolves {result, sessionId, stderr, context} | Agent SDK, session-slots, bounded-integer |
| server/lib/stdio-agent-pool.js (+acp-, codex-session-pool.js) | shared JSON-RPC stdio pool + drivers. The ACP driver authenticates after initialize only when the caller passes authMethod, sends clientMeta, applies ordered config options, and lists models (listModels) when the caller passes those options; a command may add env | pool API, driver | child_process, session-slots, bounded-integer |
| server/lib/session-slots.js | shared session cap, LRU eviction and idle timers; pool-supplied background-work policy | createSessionSlots; acquireSlot/releaseSlot, pumpWaiters, clearIdleTimer/scheduleIdleClose, waiting | pool close callback |
| server/lib/sse.js | shared SSE negotiation, event writes and stream close | wantsStream, writeStreamEvent, endStream | none |
| server/lib/bounded-integer.js | bounded integer parsing with a fallback | boundedInteger | none |
| server/lib/cli-paths.js | where agent CLIs and Relay's Cursor files live: CLI lookup (PATH, then per-user fallbacks, cached a minute), Cursor's auth file and Relay's CURSOR_CONFIG_DIR | locateBin, resolveBin, commandExists, executableInPath, cursorAuthFile, CURSOR_CONFIG_DIR | none |
| server/lib/model-discovery.js | locate each CLI and read its model catalog, cached for a minute (including "not installed"); keep catalogs the CLI is asked for (Cursor over ACP, `opencode models`, Hermes' configured model) in reported-models.json | discoverModels, clearModelDiscoveryCache, parseCursorCatalog, parseOpenCodeModels, hermesModelOptions, recordReportedModels | child_process, json-store, cli-paths |
| server/lib/agent-status.js, diagnostics.js | agent install/auth state from stored CLI auth files; GET /api/diagnostics report | getAgentStatuses, clearAgentStatusCache; buildDiagnostics | agents, cli-paths (agent-status); agent-status, tokens, workdir (diagnostics) |
| server/lib/machine-info.js | CPU model, memory and GPU names (probed once), used/total of every local disk (Linux /proc/mounts block devices, macOS / and /Volumes, Windows drive letters), live mainboard/SSD/CPU/GPU temperatures (each the average of its sensors) from Linux hwmon and nvidia-smi; GET /api/machine | machineInfo | os, fs, child_process (lspci, system_profiler, powershell, nvidia-smi) |
| server/lib/credential-file.js | encrypted relay.credentials.v1 payload for QR/file onboarding | encryptCredential | crypto |
| server/lib/agent-options.js / agent-settings.js | option validation and representation / persisted per-session settings | describeAgent, normalizeSettings, getSettings/setSettings | model-discovery, json-store |
| server/lib/agent-turn.js | one solo turn, background Claude turns and the task-completion notification | runAgentTurn, responders, createBackgroundTurnHandler, createTaskCompletionNotifier | agents, history, sse |
| server/lib/group-turn.js | Swarm prompt building | parseMentions, deltaSince, buildGroupPrompt | none |
| server/lib/context-windows.js | last context window size each agent + model reported, so a conversation without a reply can still show its limit | recordContextWindow(agent, model, size), contextWindowFor(agent, model); GET /api/history returns it as `contextWindow` | json-store |
| server/lib/history.js, chat-sessions.js, groups.js, tokens.js | persistence | per-module load/save | json-store (history: own async writer) |
| server/lib/filesystem.js, workdir.js | path policy, streamed uploads under a byte cap, directory zip downloads | resolve/list/prepare, streamUploadToFile, sendDirectoryZip | tokens, fcm, cli-paths (denylist paths from their owners) |
| server/lib/usage.js, quota-*.js | quota reporting, schedules and sending them at a reset, keepalive | buildUsageReport, schedule API, createQuotaScheduleRunner | json-store, cli-paths |
| server/lib/notify.js, push.js, fcm.js | notifications | notifyAll | subscription-store |
| server/lib/terminal-manager.js | resumable PTY per token | createTerminalManager | node-pty, bounded-integer |
| app/core/lib/core/backend | authenticated transport, SSE codec, API client | ApiTransport, BackendClient | http |
| app/core/lib/core/{models,storage,credentials,notifications,platform,widgets,i18n,theme,util,settings,download} | data models, cached stores, credential decode, platform adapters, shared widgets (agent icon, code block, wallpaper and acrylic surfaces), strings, theme and status colours, helpers, app settings and one device-local wallpaper (original file on native, bounded inline copy on Web), download progress | classes; AppSettingsController wallpaper/saveWallpaper; platform prepareWallpaper/storeWallpaperImage/loadWallpaperImage | core only |
| app/core/lib/features/chat | the main screen: solo chat, Swarm, and the drawer that opens every other screen | BotChatController, GroupChatController, screens | other lib/features, lib/core |
| app/core/lib/features/quota | quota state (QuotaController, one instance created in app/shell's main.dart and shared by the strip, usage and scheduler screens) and its screens | QuotaController, screens | lib/core |
| app/core/lib/features/{cli_agents,filesystem,machines,settings,ssh} | screens + controllers per area; take BackendClient and callbacks, never BotChatController | widgets | lib/core (machines also cli_agents, ssh) |
| app/shell/lib/main.dart | creates the shared controllers and starts the app | main() | app/core |
| scripts/install/{linux,macos,windows} | install/service adapters | setup/start/stop/status/uninstall | server/scripts, PM2/launchd/Windows |

Dependency direction: server routes -> lib -> json-store; app/shell -> app/core; within app/core/lib, features/chat -> other features -> core. Nothing outside features/chat imports it, the other features import each other without cycles, and core imports no feature.

## Features

| Feature | Module | Status |
|---|---|---|
| Solo chat + sessions | routes/chat, routes/sessions, agent-turn, features/chat | active |
| Session rename (every session except Main) | routes/sessions, chat-sessions, features/chat drawer | active |
| Message Copy (all settled replies) and Edit (user messages: text back into the composer, nothing rewritten) | features/chat | active |
| Per-session agent controls (model/effort/permission/fast) | agent-options, agent-settings, chat/agent_controls | active |
| Model picker second page (bottom link): Cursor models outside its plan (`paid`), Claude/Codex models a newer one replaced (`legacy`); Swarms list first-page models only | agent-options, chat/agent_controls, chat/swarm_form_dialog | active |
| Live OpenCode models (`opencode models`: free models plus providers configured on the host) and a Hermes model page showing the host's configured model | agents (refreshAgentModels), model-discovery, agent-options | active |
| Cursor agent over ACP (design in AGENTS.md, "Agents and controls") | agents, acp-session-pool, stdio-agent-pool, agent-options, agent-status, model-discovery, usage, routes/meta, cli_agent, chat/agent_controls, chat/context_meter | active |
| Background Claude turns | claude-session-pool, agent-turn (createBackgroundTurnHandler) | active |
| Conversation context usage (used / window above the composer) | session pools, agents, agent-turn, context-windows, routes/chat, chat/context_meter | active |
| Swarms | routes/group, groups, group-turn, chat/group_chat_* | active |
| Filesystem | routes/fs, filesystem, features/filesystem | active |
| File preview (read-only, first 512 KiB of UTF-8 text, highlighted) | features/filesystem, core/widgets/code_block | active |
| Chat attachments (upload to `<workdir>/.relay/uploads/`, path appended to the draft; upload `mkdir=1` for workdir-relative paths) | routes/fs, filesystem, core/backend, features/chat | active |
| SSH terminal | routes/terminal, terminal-manager, features/ssh | active |
| Quota + schedules + keepalive | usage, quota-*, features/quota | active |
| Notifications (Web Push, FCM) | notify, push, fcm, core/notifications | active |
| Device-local shared wallpaper (explicit Save, one live opacity slider for the current theme, blur and tint number fields shared by both themes, centered cover; first-level pages (chat, home, Swarm) make every surface on the wallpaper acrylic; other pushed pages show it behind a full-page acrylic layer with solid content) | core/settings, core/widgets, features/settings, features/chat | active |
| What's new (Home entry above Tutorial; per release 1-3 plain-language highlights plus other changes in small text) | features/settings/whats_new_screen, features/chat home | active |
| Machine details hardware card (CPU, memory, GPU, temperatures refreshed every 10 s while the page is open) | machine-info, routes/meta, features/machines | active |
| Credential onboarding | server/scripts/create-credential, core/credentials, features/machines | active |
| Update check (Settings → Check for updates compares with the latest GitHub release and only reports it; no download) | features/settings | active |

Deprecated features stay listed until their code is deleted, then the row is
removed.

## Verification

Command lines are automated. The rest are manual checks in the app or on the host; a precondition in parentheses must hold first.

- `dart format --output=none --set-exit-if-changed app/core/lib app/core/test app/shell/lib` with Flutter's pinned Dart SDK -> no files changed
- `node scripts/release/check_versions.js`, `node scripts/release/check_docs.js` and `node --test scripts/release/*.test.js` -> exit 0
- `(cd app/core && flutter analyze --no-pub)` and `(cd app/shell && flutter analyze --no-pub)` -> "No issues found!"
- `(cd app/core && flutter test --no-pub)` -> "All tests passed!"
- Settings → Wallpaper: Replace image and Remove wallpaper controls appear above the preview and adjustment controls.
- Settings → Wallpaper: choosing or removing an image updates the preview before Save; import/processing displays a spinner.
- Settings → Wallpaper: one opacity slider controls the current theme, and moving it updates the preview before Save.
- Settings → Wallpaper: entering blur (0-30) or tint (0-100) updates the preview before Save; an out-of-range number displays the allowed range as an error and leaves the preview unchanged.
- Settings → Wallpaper: the preview remains visible while the keyboard is open.
- Settings → Wallpaper: Save commits one shared image, both theme opacity values, blur and tint; reopening the page shows those saved values.
- Native wallpaper storage: the original file appears under the app support `wallpaper/` directory after Save, and the previous copy is deleted.
- Switching agents keeps the same wallpaper image.
- With a wallpaper, chat chrome and both message bubbles apply the saved tint (default 55%) over the saved blur (default 6), and no blur or tint shows outside a surface's rounded corners.
- Android overscroll on wallpaper pages shows the glow edge effect; the list content does not stretch.
- With a wallpaper, chat, home and Swarm headers, banners, home cards and the drawer machine tile use acrylic surfaces; the composer surface extends to the screen bottom behind the gesture bar.
- With a wallpaper, every other pushed page (File System, Quota Usage, Settings, ...) displays blurred wallpaper under a 72% tint and solid content.
- An empty chat with a wallpaper displays neither an agent icon nor "Start chatting" text; removing the image restores solid surfaces and that placeholder.
- `(cd server && git ls-files '*.js' | xargs -r -n1 node --check)` -> exit 0
- `npm --prefix server run lint` -> exit 0, no problems reported
- `npm --prefix server test` -> "# fail 0"
- On Windows, `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/release/test_windows_setup.ps1` -> setup contract passed, without host service changes.
- On Windows, `scripts/release/build_windows_setup.ps1 -OutputPath build/setup/Setup.exe` -> GUI compiles with the system .NET Framework compiler.
- Windows release bundle: `Setup.exe` and `setup.cmd` provide install/reinstall, CLI selection, Web on/off, all three network modes, status, token create/delete/list/re-show and uninstall with retained backend state; Web and API share Node.
- `(cd server && node -e "require('node-pty')")` -> exit 0
- `(cd app/shell && flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn)` -> exit 0, `app/shell/build/web/index.html` exists; `app/shell/build/web/assets/FontManifest.json` lists `packages/relay_core/RelayTerminalMono`
- `(cd app/shell && flutter build apk --debug --no-pub)` -> exit 0 without a release signing key
- CI runs the backend suite on Linux with Node 22 and 24 and on Windows and macOS with Node 24; it builds the Windows desktop client and an unsigned iOS client.
- `(cd app/shell && flutter build apk --release --no-pub)` -> fails naming `android/key.properties` when it is missing; with it, `apksigner verify --print-certs` on the APK shows SHA-256 `3e4dea3f6cd50fd30b25a168ba9eb2c14a14ecb8f786ffcb4e3c1836275a720f`
- Home: a What's new section sits above Tutorial; its entry shows the newest version and highlight names and opens a page listing 1-3 highlights per release with other changes in small text, in English and Chinese.
- Drawer: every session except Main has a rename button; a new name shows in the list and the chat header without changing the active session.
- Solo chat: a settled message shows Copy; a user message also shows Edit, which puts its text in the composer and sends nothing.
- File browser: tapping a UTF-8 text file shows its contents; a file containing a NUL byte shows "Cannot preview this file."; past 512 KiB it shows "Only the first 512 KiB is shown."
- Solo chat + → Attach file: the file appears as `<workdir>/.relay/uploads/<yyyyMMdd-HHmmss>-<name>` and its relative path is appended to the draft, nothing sent.
- (Linux host without Relay) `curl -fsSL https://github.com/elin66alpha/Relay/releases/latest/download/install.sh | bash` asks for a directory (default `~/relay`), unpacks the release there and starts setup at Step 1/5 without the menu; running it again prints "Upgraded to <version>" and `server/.env` is unchanged.
- Linux setup → 5 (Install agent CLIs): lists Claude Code, Codex, Cursor, OpenCode and Hermes with ✔ installed / ✘ not installed matching `GET /api/agents` `installed`; Enter installs nothing; each installed pick prints its login command.
- Machine details: Enter SSH comes first; the card below it shows the machine name, CPU model with thread count, memory, one row per GPU, one row per disk as `<mount>  <used> used / <total> total` matching `df` on the host, and at most four temperature tiles in the order Mainboard, SSD, CPU, GPU, each the average of that part's sensors (Linux; others show only GPU via nvidia-smi or "No readable temperature sensors"); the tile values change within 10 s of a temperature change, and the status text below has no Backend online, timeout, quota watch, transfer limit, token, runtime counter or Web build lines.
- Settings → Check for updates: on the latest version it shows "You are on the latest version, <version>"; when GitHub's latest release tag is higher it shows "Version <tag> is available on GitHub Releases"; offline it shows "Could not check for updates. Try again later."
- `grep -rn "import '\.\./chat/\|features/chat/" app/core/lib/features --include=*.dart | grep -v '^app/core/lib/features/chat/'` -> no output
- `grep -rn "features/" app/core/lib/core --include=*.dart` -> no output
- After a reply in solo chat with Claude Code, Codex, OpenCode, or Hermes, the line above the composer shows `<used> / <window>` (e.g. `42k / 200k`) at its right end. A new or cleared conversation shows `0 / <window>`; a conversation whose replies predate the feature shows `? / <window>`; `<window>` reads `?` until that agent + model has replied once. With Cursor active, that line is absent.
- (Cursor signed in on a Premium plan) Quota Usage lists Cursor after Codex. The Cursor card shows plan `Premium` and one weekly remaining percent with a reset time. While Cursor is the active agent, the composer strip shows that same percent. Scheduled messages stay Claude Code and Codex only.
- (Cursor signed in on the host with `agent login`) Within a minute of backend start, `server/reported-models.json` holds a `cursor` list with plain ids (`default`, `grok-4.7`, ...), and Cursor's model picker shows those names with Auto selected by default; a model with effort levels (e.g. Grok 4.7) shows its effort choices, and the model page has the Fast switch.
- (Cursor signed in) Two Cursor conversations with different models or effort answer at the same time; `ps -ef | grep 'agent acp'` shows one process per distinct choice.
- (Cursor signed in) After Cursor turns in Relay, `model` and `permissions.allow` in `~/.cursor/cli-config.json` are unchanged, and `~/.cursor/acp-sessions/` gains no directory.
- Deleting a Cursor session in the drawer removes its directory under `server/cursor-config/acp-sessions/`.
- Model page: Claude Code lists Opus 5.5, Sonnet 5.5, Haiku 5.5 and Fable 5.1 with a bottom "Legacy models (15)" link; Codex lists GPT-6.1-Sol, GPT-6-Astra and GPT-6-Luna with "Legacy models (4)"; Cursor lists Auto, Grok 4.7, 4.6, 4.5 and Composer 2.5 with "Models that need a payment method (41)" (counts as of 2026-10-26). Choosing a model on that second page saves it and returns to chat; reopening shows "Current: <model>" under the link. A Swarm member's model dropdown lists only first-page models.
- Within a minute of backend start, OpenCode's model page lists exactly the ids `opencode models` prints on the host, each as model name over provider; a provider added to the host's OpenCode config appears after the next picker open more than ten minutes later, or after Update CLI.
- Hermes shows a Model entry; its page lists one choice, the name `hermes config get model.default` prints, with the provider under it.
- `GET /api/agents` lists keys in order `claude`, `codex`, `cursor`, `opencode`, `hermes`. Cursor is usable only when the `agent` binary is installed and the host auth file has both tokens, or `CURSOR_API_KEY` is set. The response does not contain the token.

## Milestones

| Milestone | Completion criteria | Status |
|---|---|---|
| 0.1.7 | Released with app, server and changelog versions at 0.1.7 | done |
| 0.1.8 | Released with app, server, changelog and What's new versions at 0.1.8 | done |
| 0.1.9 | Released with app, server, changelog and What's new versions at 0.1.9 | done |
| 0.1.10 | At release: `app/shell/pubspec.yaml`, `server/package.json` and `_applicationVersion` in `app/core/lib/features/settings/app_settings_screen.dart` read 0.1.10; `docs/CHANGELOG.md` and `app/core/lib/features/settings/whats_new_screen.dart` have 0.1.10 entries (English and Chinese, 1-3 highlights plus short other-change lines in What's new); no document describes the pre-0.1.10 layout (`backends/`, root `lib/`, `test/`, `assets/` or platform folders) | in progress |

## Changes

Architecture-level changes only. Keep the latest 10; fold older entries into
one summary line.

- Before 2026-10-17: server routes split out of server.js into server/routes (2026-06-10); agent controls persisted per workdir + agent + session (2026-10-02).
- 2026-10-17: feature dependencies made acyclic: the drawer moved into features/chat, quota state moved from BotChatController to features/quota QuotaController, non-chat features take BackendClient and callbacks. Reason: features/* imported BotChatController and formed three cycles.
- 2026-10-17: code_block.dart moved from features/chat to core/widgets. Reason: the file preview reuses it, and features must not import each other.
- 2026-10-17: added server/lib/context-windows.js (state file context-windows.json). Reason: no CLI exposes a model's context window before a reply, so the last reported size per agent + model is remembered.
- 2026-10-18: upload streaming and zip download moved from server.js to lib/filesystem.js, background turns and the task-completion notification to lib/agent-turn.js, the scheduled-message runner to lib/quota-schedules.js. Reason: server.js loads by starting the server, so that logic could not be tested.
- 2026-10-18: extracted session-slots for both session pools, sse for solo/Swarm streams and bounded-integer for pools/terminal settings. Reason: duplicated cap/eviction/idle policies and helpers could drift; Claude retains its background-work exemptions.
- 2026-10-25: ACP pool gained an optional authenticate step so Cursor joins the existing session pool. Reason: Cursor's CLI rejects a session until `cursor_login`.
- 2026-10-25: Cursor runs one ACP process per model choice under Relay's own CURSOR_CONFIG_DIR (server/cursor-config/), with its catalog kept by model-discovery (state file reported-models.json). Reason: Cursor applies a model to its whole process and persists every choice as the host CLI's default, and its ACP server accepts none of the `agent --list-models` ids.
- 2026-10-26: added server/lib/cli-paths.js; agents.js and model-discovery.js share its CLI lookup, and filesystem.js takes Cursor's paths from it. Reason: the two lookups could disagree on whether a CLI is installed, and the path policy loaded the whole process runner for one constant.
- 2026-10-26: chat screens split by responsibility (home page, history search, input bar, message bubble, Swarm form, work-tree picker, push registration), and routes take everything with state or I/O from routeContext while requiring built-ins directly. Reason: the chat files mixed five or six concerns and were the change hotspots, and routes had no rule for where a dependency comes from.
- 2026-10-29: repository regrouped by role: the Flutter client into app/core (package relay_core: screens, logic, tests, assets) and app/shell (main.dart and the platform projects), every install, release and dev script into scripts/{install,release,dev}, and documentation into docs/. Reason: front end and back end were indistinguishable at the root, backends/ and server/ read as two backends, and scripts/ mixed user installers with developer tools.

## Review

Last review: 2026-10-26
Features since last review: 0
Last result: Intent Problem, Structure OK, Entropy Problem, Test value Problem, Documentation Problem, Operability Problem, Evolution OK, Performance Problem; 6 open findings (0.1.9: Cursor child-process environment regression coverage, catalog refresh coordinator coverage, silent catalog/config failures, environment-specific verification assumptions, and incomplete documentation updates; existing: whole-history serialization measured at 145.83-181.10 ms for 500 synthetic scopes / 55.66 MB). Independent audit of ef5d04e..7cbffcd; clean exported checkout passed Flutter analysis, 148 Flutter tests, 308 backend tests, backend lint/syntax/native PTY loading, Web build and isolated HTTP startup; unsigned APK attempt failed at the documented missing android/key.properties guard.

## Deviations

- [open] 2026-10-17: history.js keeps its own JSON writer instead of json-store. Reason: history needs debounced async writes.
- [closed] 2026-10-17: features/* import features/chat/bot_chat_controller (reverse edges). Reason: none given; BotChatController predates the split. Closed 2026-10-17: no feature outside chat imports it.
