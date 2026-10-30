# ENGINEERING.md

Engineering contract for this repository. Every agent reads this before any
change. It holds what Relay is, its modules, and the constraints on them, with
the reason for each. How agents work together in this workspace lives in
`AGENTS.md`; operational detail lives in `docs/handbook.md`.

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
| scripts/dev | local development helpers (build flow, backend restart, icon export, README screenshots) |
| docs | handbook, install guides, security model, changelog, README screenshots |
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
| server/lib/history.js, chat-sessions.js, groups.js, tokens.js | persistence | per-module load/save | json-store (history: own writer: background flush writes scope by scope in chunks; a file that exists but cannot be loaded is renamed to `<file>.corrupt-<time>` before history starts empty) |
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

## Invariants

Constraints that hold across modules, each with its reason. Breaking one is an
architecture change (see Changes).

### Scope and concurrency

- A device stores its active workdir locally, one per machine, and sends it as
  `X-Workdir` on every request to that machine. There is no global backend
  workdir, and a path never goes to a backend it was not chosen on.
- A conversation is scoped by `workdir + agent + sessionId`. Each agent context
  supports at most eight named sessions; `Main` cannot be deleted or renamed
  because it preserves the legacy scope key and the original conversation from
  before named sessions existed.
- Turns in the same exact conversation scope serialize through `scopeChains`.
  Different sessions and different Swarm members may run concurrently.
- Agent controls belong to a conversation: model, effort, permission, and fast
  mode persist per `workdir + agent + sessionId`, shared by every device on that
  session. A new session copies the settings of the session it was created from;
  a session with no entry of its own falls back to Main's (the context key).
  Requests without a `sessionId` address Main, so older clients keep working.

### Agents and controls

- `server/lib/agents.js` is the process-runner boundary. Pass per-request state
  through `runAgent(..., { workdir, settings, sessionKey })`; do not add globals,
  because different conversation scopes run concurrently.
- `server/lib/agent-options.js` owns option validation and the SDK or
  protocol representation of each setting. `server/lib/agent-settings.js`
  persists normalized solo-chat settings.
- No agent runs one process per turn. All five keep a live session that turns
  are fed into. Every pool is a *cache*: the stored session id stays
  authoritative, so any scope without a live session cold-starts by resuming it
  and degrades to exactly the old per-turn behaviour. Do not reintroduce a
  per-turn `spawn` for an agent that has a pool, because it repeats CLI startup
  and cuts off background work when the process exits.
  - `server/lib/claude-session-pool.js` — one Agent SDK process per scope.
    Settings resolve to SDK options (`claudeSdkOptions`) rather than argv, and
    are fixed for the life of a process, so a change restarts it with `resume`.
    Claude also runs turns nobody sent (a background task finishing, or resume
    after one was cut off), which end in a `result` too: a turn settles only on
    the result whose `user_message_uuid` names the message it pushed. Running
    background tasks keep a process from idle eviction. A turn Claude starts
    while idle is a background turn: in solo chat it becomes a reply of its
    own, queued on the scope and stopped by Stop like any turn, once it
    writes text. A message pushed while it runs may be folded into it; the
    result naming that message then ends both.
  - `server/lib/stdio-agent-pool.js` — the shared pool for the three CLIs that
    speak line-delimited JSON-RPC on stdio. It owns the process, the wire, the
    session cap, idle eviction and cancellation; a `driver` supplies the
    protocol. One process per agent hosts *all* of that agent's scopes, since
    each session carries its own `cwd`, so a large startup cost is paid once
    instead of once per chat.
    - `acp-session-pool.js` — the ACP driver (opencode, hermes, cursor). Settings apply
      over the protocol (`acpSessionOptions`) with no restart. Capabilities from
      `initialize` gate optional calls: hermes has no `session/close`, so an
      evicted session is simply dropped.
    - `codex-session-pool.js` — the codex app-server driver. `turn/start`
      returns as soon as the turn is *accepted*; the turn is settled by the
      later `turn/completed` notification. Everything except the sandbox applies
      per turn (`codexSessionOptions`), and the sandbox is what the runner
      passes as `fixedKey` so a change reopens the thread — still resuming the
      same conversation, without respawning the process.
  - Relay answers the agents' approval requests from the configured tier,
    because there is no approval UI to route them to. The runner's policy
    answers yes or no; translating that into each protocol's vocabulary is the
    driver's job (`allow_once` vs `accept` vs `approved`). ACP approvals pick
    `allow_once` over `allow_always`, because Cursor persists an "always" into
    the host user's own CLI allowlist.
  - `runAcpAgent` in `agents.js` is the shared runner for opencode, hermes, and
    cursor, which differ only by their pool and their entries in the option
    tables. Cursor's binary is `agent`; its pool passes `authMethod:
    cursor_login` because the CLI rejects a session until that call.
    - Cursor applies a model and its parameters to the whole process and
      persists each choice into its config as the CLI's default. Relay's
      Cursor therefore runs with its own `CURSOR_CONFIG_DIR`
      (`server/cursor-config/`, override `RELAY_CURSOR_CONFIG_DIR`) so it never
      changes the host user's `~/.cursor`, and every distinct
      model + effort + fast choice gets its own process (`cursorPoolFor`);
      scopes with the same choice share one. A scope whose choice changes is
      forgotten in its old process and resumes in the new one.
    - Settings are ACP config options in the parameterized model picker
      (`clientMeta: { parameterizedModelPicker: true }`): the model first,
      since choosing it resets its parameters, then its thought-level option
      as effort and `fast`. `agent --list-models` ids are not accepted over
      ACP. The catalog comes from `cursor/list_available_models` (no session
      needed), recorded through `recordCursorCatalog` in `model-discovery.js`
      at startup, after a CLI update, and on picker opens at most every ten
      minutes. Cursor emits no context usage, so the app hides the meter.
  - `refreshAgentModels` uses the same schedule for OpenCode, whose list is
    `opencode models` (free models change on OpenCode's side, and it includes
    every provider configured on the host), and for Hermes, whose picker
    shows only the host's configured model as `default`. `acpSessionOptions`
    never sends `default` to Hermes, so it keeps running that model.
- `agent-options.js` marks each model with an optional `group` the picker lists
  on a second page: Cursor models other than Auto, Grok and Composer are `paid`
  (the Cursor plan covers only those; the rest bill prepaid usage), and a
  Claude or Codex model is `legacy` when a newer version of its family exists or
  its family has no model in the newest major generation. Ids of unknown shape
  stay on the first page. A grouped model stays valid everywhere; Swarms list
  only first-page models.
- Deleting or clearing a conversation goes through `purgeSession`, not
  `clearSession`: for a pooled agent it also requests CLI-side transcript
  deletion on a best-effort basis. Cursor has no delete command, so Relay
  removes `<CURSOR_CONFIG_DIR>/acp-sessions/<id>` itself. Use `clearSession` only for the internal
  stale-session retry.
- Fast mode is a control for Claude Code, Codex, and Cursor and defaults off.
  Claude receives a `fastMode` settings override; Codex receives an explicit
  `serviceTier` of `fast` or `default` on every turn; Cursor receives `fast`
  `true` or `false` for every model that has the option.
- Codex models and model-specific reasoning levels come from structured CLI
  metadata, with bundled/cache/static fallbacks. Do not reintroduce binary
  string scanning for Codex model ids, because it can mistake a model-name
  prefix for a supported model and loses per-model reasoning choices.
- `describeAgent` and `getSettings` are hot paths for option refreshes and every
  turn, so keep them free of subprocesses and per-call file reads.
  `model-discovery.js` re-locates a CLI at most once a minute and caches the
  result (including "not installed"); `agent-options.js` caches
  `models-extra.json` by mtime. A CLI update calls `clearModelDiscoveryCache`,
  which is what makes new models appear at once.
- `GET /api/agents` returns all five known agents with install/auth/usability
  state, in the order Claude Code, Codex, Cursor, OpenCode, Hermes. Claude and
  Cursor require their CLI login (Cursor also accepts `CURSOR_API_KEY`). Codex reports its active app-server auth mode,
  including managed ChatGPT, API-key, external-token, and host-managed provider
  modes; OpenCode and Hermes credentials are managed on the host and become
  selectable when installed.
- Every credential is created on the backend host by the CLI itself. Relay does
  not log an agent in. `server/lib/agent-status.js` reads stored auth state.
  Relay reports no login deadline because every supported CLI refreshes its
  tokens. An explicit credential recheck
  uses `account/read` with `refreshToken: true` on the shared Codex app-server.
  `server/lib/usage.js` separately reads and may refresh OAuth credentials for
  quota reporting and keepalive. A token or account identity value must never
  reach Relay's API or app, because agent credentials and account details stay
  on the backend host rather than being shared with every connected device.

### Backend modules and persistence

- Each route factory receives through `routeContext` everything that holds state
  or does I/O: server state, persistence, processes, caches, and the helpers
  `server.js` builds. Tests replace those. A route requires directly only Node
  built-ins, npm packages, and `lib/*` helpers that compute from their arguments
  (SSE writers, Swarm prompt building, settings validation). When a route
  destructures a new helper, add it to the context in `server/server.js`.
- Use `server/lib/json-store.js` for JSON state: cached reads, atomic replace,
  and owner-only file permissions. Do not create ad hoc read/modify/write stores.
- A generated state file may accept a `RELAY_*_FILE` absolute-path override so
  its module is testable without touching deployment state. When adding one to a
  file that the file API denies, take the path from the owning module rather than
  rebuilding it in `server/lib/filesystem.js`.
- New notifications should go through `server/lib/notify.js`, which fans out to
  configured Web Push and FCM channels.
- Chat prompt payloads and generated Swarm prompts are capped by
  `PROMPT_MAX_BYTES`. Preserve that validation in every chat path.

### Client boundaries

- `app/core/lib/core/backend/api_transport.dart` is the shared authenticated
  transport.
  Reuse it instead of duplicating base URL, bearer token, device headers, or
  error handling.
- Credential decryption and large history decoding stay off the UI isolate.
- `MachineCredentialsStore`, `DeviceIdStore`, and `WorkdirStore` use static
  caches because multiple instances exist. Every new write path must invalidate
  the corresponding cache.
- The shared `/api/events` stream is workdir-aware and has an idle timeout so a
  dead connection reconnects. Preserve scope filters when adding events.

### Files, Swarms, and side conversations

- The file API accepts absolute paths and is filesystem-wide by default, but
  always applies the precise sensitive-path denylist and optional
  `RELAY_FS_ROOTS` allowlist in `server/lib/filesystem.js`.
- A Swarm owns one canonical transcript and private resumable sessions per
  member. A round runs in waves: each wave snapshots the transcript once and
  runs everyone summoned in it in parallel from their own delta prompts. The
  human's `@mentions` open wave one; `@mentions` inside a member's reply summon
  the next wave, bounded by `RELAY_SWARM_MAX_HOPS` (default 3, 0 disables) since
  two members naming each other would otherwise never stop. A member never
  summons itself, and a failed or cancelled turn summons no one. One round runs
  at a time: a message sent meanwhile is refused (`GROUP_BUSY`), and the Swarm
  history reports the running round (`runningRequestId`) so a reopened screen
  still offers Stop. The app shows a member as working until its reply is
  complete; Swarm replies are not streamed.
- Swarm configuration is stored under the workspace that lists it, while its
  chosen work tree is the directory members actually use.
- The SSH terminal exchanges the bearer credential for a short-lived,
  single-use WebSocket ticket. Never put the bearer token in a socket URL,
  because URLs can expose it through access logs. A token record owns one
  resumable PTY, which runs with the full permissions of
  the backend OS user and is not constrained by the file API denylist. Keep its
  bundled `RelayTerminalMono` family as xterm's primary font: using generic
  `monospace` can produce overly wide character cells in Chromium.

### Client packaging

  are addressed with `package: 'relay_core'` or a `packages/relay_core/`
  prefix. `app/shell` adds only the platform projects and `main.dart`.
- `.github/workflows/ci.yml` runs the verification commands on pull requests.

## Features

| Feature | Module | Status |
|---|---|---|
| Solo chat + sessions | routes/chat, routes/sessions, agent-turn, features/chat | active |
| Session rename (every session except Main) | routes/sessions, chat-sessions, features/chat drawer | active |
| Message Copy (all settled replies) and Edit (user messages: text back into the composer, nothing rewritten) | features/chat | active |
| Per-session agent controls (model/effort/permission/fast) | agent-options, agent-settings, chat/agent_controls | active |
| Model picker second page (bottom link): Cursor models outside its plan (`paid`), Claude/Codex models a newer one replaced (`legacy`); Swarms list first-page models only | agent-options, chat/agent_controls, chat/swarm_form_dialog | active |
| Live OpenCode models (`opencode models`: free models plus providers configured on the host) and a Hermes model page showing the host's configured model | agents (refreshAgentModels), model-discovery, agent-options | active |
| Cursor agent over ACP (design under Invariants, "Agents and controls") | agents, acp-session-pool, stdio-agent-pool, agent-options, agent-status, model-discovery, usage, routes/meta, cli_agent, chat/agent_controls, chat/context_meter | active |
| Background Claude turns | claude-session-pool, agent-turn (createBackgroundTurnHandler) | active |
| Conversation context usage (used / window above the composer) | session pools, agents, agent-turn, context-windows, routes/chat, chat/context_meter | active |
| Swarms | routes/group, groups, group-turn, chat/group_chat_* | active |
| Filesystem | routes/fs, filesystem, features/filesystem | active |
| File preview (read-only, first 512 KiB of UTF-8 text, highlighted) | features/filesystem, core/widgets/code_block | active |
| Chat attachments (upload to `<workdir>/.relay/uploads/`, path appended to the draft; upload `mkdir=1` for workdir-relative paths) | routes/fs, filesystem, core/backend, features/chat | active |
| SSH terminal | routes/terminal, terminal-manager, features/ssh | active |
| Quota + schedules + keepalive | usage, quota-*, features/quota | active |
| Notifications (Web Push, FCM) | notify, push, fcm, core/notifications | active |
| Device-local wallpaper with acrylic surfaces (behavior under Verification) | core/settings, core/widgets, features/settings, features/chat | active |
| What's new (Home entry above Tutorial; per release 1-3 plain-language highlights plus other changes in small text) | features/settings/whats_new_screen, features/chat home | active |
| Machine details hardware card (CPU, memory, GPU, temperatures refreshed every 10 s while the page is open) | machine-info, routes/meta, features/machines | active |
| Credential onboarding | server/scripts/create-credential, core/credentials, features/machines | active |
| Update check (Settings → Check for updates compares with the latest GitHub release and only reports it; no download) | features/settings | active |

Deprecated features stay listed until their code is deleted, then the row is
removed.

## Verification

Command lines are automated. The rest are manual checks in the app or on the host; a precondition in parentheses must hold first.

- `dart format --output=none --set-exit-if-changed app/core/lib app/core/test app/shell/lib` with Flutter's pinned Dart SDK -> no files changed
- `flutter pub get --enforce-lockfile` in both `app/core` and `app/shell` with Flutter 3.44.8 -> exit 0 without changing the lock files
- `node scripts/release/check_versions.js`, `node scripts/release/check_docs.js` and `node --test scripts/release/*.test.js` -> exit 0
- `(cd app/core && flutter analyze --no-pub)` and `(cd app/shell && flutter analyze --no-pub)` -> "No issues found!"
- `(cd app/core && flutter test --no-pub)` -> "All tests passed!"
- `node scripts/dev/readme_screenshots.js <wallpaper image> --mobile-zh` (Web build present) -> nine Chinese demo screenshots (home, chat, empty chat, Swarm, files, machine details, quota usage, settings and credentials) in `docs/screenshots/mobile-zh-9x16/`, each 1080×1920 (9:16), with translated demo conversations and the README wallpaper settings.
- Settings → Wallpaper: Replace image and Remove wallpaper controls appear above the preview and adjustment controls.
- Settings → Wallpaper: choosing or removing an image updates the preview before Save; import/processing displays a spinner.
- Settings → Wallpaper: one opacity slider controls the current theme, and moving it updates the preview before Save.
- Settings → Wallpaper: entering blur (0-30) or tint (0-100) updates the preview before Save; an out-of-range number displays the allowed range as an error and leaves the preview unchanged.
- Settings → Wallpaper: the preview remains visible while the keyboard is open.
- Settings → Wallpaper: Save commits one shared image, both theme opacity values, blur and tint; reopening the page shows those saved values.
- Native wallpaper storage: the original file appears under the app support `wallpaper/` directory after Save, and the previous copy is deleted.
- Switching agents keeps the same wallpaper image.
- With a wallpaper, chat chrome and both message bubbles apply the saved tint (default 55%) over the saved blur (default 6), and no blur or tint shows outside a surface's rounded corners.
- Android overscroll on wallpaper pages shows the glow edge effect and list items keep their size.
- With a wallpaper, chat, home and Swarm headers, banners, home cards and the drawer machine tile use acrylic surfaces; the composer surface extends to the screen bottom behind the gesture bar.
- With a wallpaper, every other pushed page (File System, Quota Usage, Settings, ...) displays blurred wallpaper under a 72% tint and solid content.
- An empty chat with a wallpaper displays neither an agent icon nor "Start chatting" text; removing the image restores solid surfaces and that placeholder.
- `(cd server && git ls-files '*.js' | xargs -r -n1 node --check)` -> exit 0
- `npm --prefix server run lint` -> exit 0, no problems reported
- `npm --prefix server test` -> "# fail 0"
- `npm --prefix server audit --omit=dev --audit-level=high` -> no high or critical production dependency vulnerabilities
- On Windows, `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/release/test_windows_setup.ps1` -> setup contract passed, without host service changes.
- On Windows, `scripts/release/build_windows_setup.ps1 -OutputPath build/setup/Setup.exe` -> GUI compiles with the system .NET Framework compiler.
- Windows release bundle: `Setup.exe` and `setup.cmd` provide install/reinstall, CLI selection, Web on/off, all three network modes, status, token create/delete/list/re-show and uninstall with retained backend state; Web and API share Node.
- `(cd server && node -e "require('node-pty')")` -> exit 0
- `(cd app/shell && flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn)` -> exit 0, `app/shell/build/web/index.html` exists; `app/shell/build/web/assets/FontManifest.json` lists `packages/relay_core/RelayTerminalMono`
- `(cd app/shell && flutter build linux --release --no-pub)` -> exit 0, `app/shell/build/linux/x64/release/bundle/relay` exists on Ubuntu with GTK and libsecret development files installed
- `./scripts/release/package_linux_desktop.sh` on Ubuntu 22.04 after the Linux build -> an amd64 `.deb` and checksum in `build/release/`, with the desktop launcher and hicolor icons; installation adds Relay to the applications menu.
- (Ubuntu desktop with an unlocked GNOME Keyring) a test machine credential survives an app restart and is removed when deleted.
- `(cd app/shell && flutter build apk --debug --no-pub)` -> exit 0 without a release signing key
- CI runs the backend suite on Linux with Node 22 and 24 and on Windows and macOS with Node 24; it builds the Linux desktop client on Ubuntu 22.04 and the latest Ubuntu runner, packages the Ubuntu 22.04 build, and builds the Windows desktop client, an unsigned iOS client and the macOS client.
- `(cd app/shell && flutter build apk --release --no-pub)` -> fails naming `android/key.properties` when it is missing; with it, `apksigner verify --print-certs` on the APK shows the SHA-256 that `scripts/release/add_signed_android.sh` expects (`expected_cert`)
- Home: a What's new section sits above Tutorial; its entry shows the newest version and highlight names and opens a page listing 1-3 highlights per release with other changes in small text, in English and Chinese.
- Drawer: every session except Main has a rename button; a new name shows in the list and the chat header without changing the active session.
- Solo chat: a settled message shows Copy; a user message also shows Edit, which puts its text in the composer and sends nothing.
- File browser: tapping a UTF-8 text file shows its contents; a file containing a NUL byte shows "Cannot preview this file."; past 512 KiB it shows "Only the first 512 KiB is shown."
- Solo chat + → Attach file: the file appears as `<workdir>/.relay/uploads/<yyyyMMdd-HHmmss>-<name>` and its relative path is appended to the draft, nothing sent.
- (Linux host without Relay) `curl -fsSL https://github.com/elin66alpha/Relay/releases/latest/download/install.sh | bash` asks for a directory (default `~/relay`), unpacks the release there and starts setup at Step 1/5 without the menu; running it again prints "Upgraded to <version>" and `server/.env` is unchanged.
- Linux setup → 5 (Install agent CLIs): lists Claude Code, Codex, Cursor, OpenCode and Hermes with ✔ installed / ✘ not installed matching `GET /api/agents` `installed`; Enter installs nothing; each installed pick prints its login command.
- Machine details: Enter SSH comes first, then a card with the machine name, CPU model with thread count, memory, one row per GPU, and one row per disk as `<mount>  <used> used / <total> total` matching `df` on the host.
- Machine details temperatures: at most four tiles in the order Mainboard, SSD, CPU, GPU, each the average of that part's sensors (Linux; other systems show only GPU via nvidia-smi or "No readable temperature sensors"); a tile changes within 10 s of a temperature change.
- Machine details status text has no Backend online, timeout, quota watch, transfer limit, token, runtime counter or Web build lines.
- Settings → Check for updates: on the latest version it shows "You are on the latest version, <version>"; when GitHub's latest release tag is higher it shows "Version <tag> is available on GitHub Releases"; offline it shows "Could not check for updates. Try again later."
- `grep -rn "import '\.\./chat/\|features/chat/" app/core/lib/features --include=*.dart | grep -v '^app/core/lib/features/chat/'` -> no output
- `grep -rn "features/" app/core/lib/core --include=*.dart` -> no output
- After a reply in solo chat with Claude Code, Codex, OpenCode, or Hermes, the line above the composer ends with `<used> / <window>` (e.g. `42k / 200k`); `<window>` reads `?` until that agent + model has replied once.
- A new or cleared conversation shows `0 / <window>`; one whose replies predate the feature shows `? / <window>`; with Cursor active the line is absent.
- (Cursor signed in on a Premium plan) Quota Usage lists Cursor after Codex. The Cursor card shows plan `Premium` and one weekly remaining percent with a reset time. While Cursor is the active agent, the composer strip shows that same percent. Scheduled messages stay Claude Code and Codex only.
- (Cursor signed in on the host with `agent login`) Within a minute of backend start, `server/reported-models.json` holds a `cursor` list of plain ids (`default`, ...); Cursor's model picker shows those names with Auto selected, a model with effort levels shows its effort choices, and the model page has the Fast switch.
- (Cursor signed in) Two Cursor conversations with different models or effort answer at the same time; `ps -ef | grep 'agent acp'` shows one process per distinct choice.
- (Cursor signed in) After Cursor turns in Relay, `model` and `permissions.allow` in `~/.cursor/cli-config.json` are unchanged, and `~/.cursor/acp-sessions/` gains no directory.
- Deleting a Cursor session in the drawer removes its directory under `server/cursor-config/acp-sessions/`.
- (Backend host) With invalid JSON in `server/chat-history.json`, start the backend: chat history is empty, the backend log has a `[history]` warning, and `server/chat-history.json.corrupt-<time>` holds the original bytes.
- Model page: a model with `group` `legacy` (Claude Code, Codex) or `paid` (Cursor) in `GET /api/agent-options?agent=<key>` is listed only behind the bottom link, whose label shows how many there are; every other model is on the first page. Choosing a model on the second page saves it and returns to chat; reopening shows "Current: <model>" under the link. A Swarm member's model dropdown lists only first-page models.
- Within a minute of backend start, OpenCode's model page lists exactly the ids `opencode models` prints on the host, each as model name over provider; a provider added to the host's OpenCode config appears after the next picker open more than ten minutes later, or after Update CLI.
- Hermes shows a Model entry; its page lists one choice, the name `hermes config get model.default` prints, with the provider under it.
- `GET /api/agents` lists keys in order `claude`, `codex`, `cursor`, `opencode`, `hermes`. Cursor is usable only when the `agent` binary is installed and the host auth file has both tokens, or `CURSOR_API_KEY` is set. The response does not contain the token.

## Milestones

| Milestone | Completion criteria | Status |
|---|---|---|
| 0.1.10 | `node scripts/release/check_versions.js` prints "Release versions match: 0.1.10"; the What's new entries (English and Chinese) hold 1-3 highlights plus short other-change lines; the repository root has no directory named backends, lib, test or assets, and ``git grep -n 'backends[/]' -- '*.md' ':!docs/CHANGELOG.md' ':!docs/releases'`` prints nothing | in progress |

## Changes

Architecture-level changes only. Keep the latest 10; fold older entries into
one summary line.

- Before 2026-10-18: server routes split into server/routes (2026-06-10); agent controls persisted per workdir + agent + session (2026-10-02); feature dependencies made acyclic, with the drawer, quota state and code_block.dart moved so features never import each other (2026-10-17); context-windows.js added because no CLI exposes a model's context window before a reply (2026-10-17).
- 2026-10-18: upload/zip, background turns and the scheduled-message runner moved from server.js into lib/ modules. Reason: server.js loads by starting the server, so that logic could not be tested.
- 2026-10-18: extracted session-slots, sse and bounded-integer from the session pools and streams. Reason: duplicated cap/eviction/idle policies and helpers could drift.
- 2026-10-25: ACP pool gained an optional authenticate step so Cursor joins the existing session pool. Reason: Cursor's CLI rejects a session until `cursor_login`.
- 2026-10-25: Cursor runs one ACP process per model choice under Relay's own CURSOR_CONFIG_DIR (server/cursor-config/), with its catalog kept by model-discovery (state file reported-models.json). Reason: Cursor applies a model to its whole process and persists every choice as the host CLI's default, and its ACP server accepts none of the `agent --list-models` ids.
- 2026-10-26: added server/lib/cli-paths.js; agents.js and model-discovery.js share its CLI lookup, and filesystem.js takes Cursor's paths from it. Reason: the two lookups could disagree on whether a CLI is installed, and the path policy loaded the whole process runner for one constant.
- 2026-10-26: chat screens split by responsibility, and routes take state and I/O from routeContext while requiring built-ins directly. Reason: the chat files mixed five or six concerns and were the change hotspots, and routes had no rule for where a dependency comes from.
- 2026-10-29: repository regrouped by role into app/{core,shell}, scripts/{install,release,dev} and docs/. Reason: front end and back end were indistinguishable at the root, the old backends directory and server/ read as two backends, and scripts/ mixed user installers with developer tools.
- 2026-10-29: design constraints moved from AGENTS.md into ENGINEERING.md (Invariants); AGENTS.md keeps the working rules for agents that share the workspace. Reason: the constraints are part of the system's design and belong with the module map, and two copies drifted apart.

## Review

Last review: 2026-10-29
Features since last review: 0
Last result: Intent OK, Structure OK, Entropy OK, Test value Problem, Documentation OK, Operability OK, Evolution OK, Performance OK; 3 open findings (no test checks that Cursor's process starts with Relay's CURSOR_CONFIG_DIR; history.js background writes never recover after one failed write; json-store overwrites a file it cannot load).

## Deviations

- [open] 2026-10-17: history.js keeps its own JSON writer instead of json-store. Reason: history needs debounced async writes.
- [closed] 2026-10-17: features/* import features/chat/bot_chat_controller (reverse edges). Reason: none given; BotChatController predates the split. Closed 2026-10-17: no feature outside chat imports it.
