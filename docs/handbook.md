# Relay handbook

This is the durable operating and architecture reference for Relay. Start with
the [README](../README.md), use the [backend setup guide](install.md)
for installation, and read [SECURITY.md](SECURITY.md) before exposing a
backend outside a trusted network.

## Production deployment

Relay carries a bearer token on every API request and can start coding agents as
the backend OS user. A stable deployment should have all of the following:

- Terminate TLS at a named Cloudflare Tunnel or a reverse proxy such as Caddy or
  Nginx. A routable `http://` `PUBLIC_BASE_URL` triggers a warning but is not
  blocked.
- Keep `HOST=127.0.0.1` when the tunnel or reverse proxy is on the same host.
  Direct mode uses `0.0.0.0`; expose it only behind HTTPS and a firewall.
- Set `PUBLIC_BASE_URL` to the exact URL imported by clients. Regenerate and
  re-import credentials after it changes.
- Run Relay as a non-root user and restrict that user's filesystem access.
- Set `RELAY_FS_ROOTS` to the absolute directories the file API should reach.
  Without it, the API is filesystem-wide except for its built-in denylist.
- Generate one credential per device. Revoke and delete old device tokens rather
  than sharing one token.
- Keep `.env`, tokens, credential exports, CLI login state, push keys, history,
  sessions, settings, `server/context-windows.json`, `server/reported-models.json`,
  `server/cursor-config/`, groups, quota state, and FCM
  service-account files out of git and release archives.

### Reverse proxy requirements

- Forward normal HTTP requests and long-lived SSE responses. Disable buffering
  for `/api/events`, `/api/chat`, and `/api/group/chat`.
- Forward `Upgrade`/`Connection` headers for the WebSocket endpoint
  `/api/terminal/connect`. Do not log its one-time `ticket` query value.
- Keep proxy timeouts above `AGENT_TIMEOUT_MS` (60 minutes by default).
- Pass the real client address in `X-Forwarded-For`. Relay trusts forwarded
  addresses only from loopback proxies.
- Match proxy body/response limits to Relay's defaults: 100 MB per upload and
  300 MB per download. Override with `UPLOAD_MAX_BYTES` and
  `DOWNLOAD_MAX_BYTES` only when the full path can handle larger transfers.
- Narrow browser access with `CORS_ALLOW_ORIGIN` when the Web app has a stable
  origin.

Relay applies a general limit of 600 ordinary API requests per minute per IP.
Long-lived chat/SSE and file-transfer endpoints are excluded from that counter
but still require authentication. Failed bearer-token attempts have a separate
15-per-minute per-IP limit.

### File API boundary

The built-in denylist currently covers Relay's token file, `.env`, generated
credential directory, Web Push/FCM token stores, the FCM service-account key,
`~/.ssh`, Claude Code OAuth
credentials, Codex auth, Cursor's `auth.json`, and Relay's own Cursor config
directory `server/cursor-config/`. It also covers siblings whose names start with a
sensitive basename followed by a dot, such as `.env.bak-x`, `tokens.json.bak`,
and `auth.json.old`, including atomic `.tmp` files. It is not a general secret
scanner and does not cover every third-party CLI configuration. Use
`RELAY_FS_ROOTS` and a restricted backend user for the actual production boundary.

Directory downloads are zipped and rejected if the tree would contain a denied
path. Native uploads/downloads stream; Web downloads use a browser Blob and may
hold the file in memory up to the configured cap. Unix directory downloads call
the host's `zip` command; Windows uses PowerShell `Compress-Archive`.

Tapping a file opens a read-only preview of its first 512 KiB of UTF-8 text,
with a notice when truncated. Binary content containing NUL bytes and invalid
UTF-8 cannot be previewed. Supported code languages are syntax-highlighted up
to 20,000 characters; larger or unrecognized content stays plain text. Preview
uses the download endpoint, so its path policy and download size limit still
apply; the download button saves the full file.

`POST /api/fs/upload?path=...&name=...` accepts `mkdir=1` to create a missing
workdir-relative upload directory and its parents. Before creation, Relay checks
workdir confinement (including existing symlink ancestors), the denylist, and
`RELAY_FS_ROOTS`. Absolute paths and requests without `mkdir=1` still require an
existing directory. Solo-chat attachments use this option for
`<workdir>/.relay/uploads/`; these files appear in the repository's git status
unless `.relay/` is ignored.

## Wallpaper

Settings → Wallpaper edits one image shared by every solo chat, Swarm and the
chat home, independent of backend, workspace and session. The device stores one
JSON preference record with the image reference, separate light/dark
opacities, and the acrylic blur and tint shared by both themes. Defaults are no
image, 80%/20% opacity, blur 6 and tint 55%. The single slider follows the
current app theme and updates the preview during dragging; the blur (0-30) and
tint (0-100%) fields below it update the preview on every valid number and show
the range as an error otherwise. The preview stays on screen while the controls
below it scroll, so it remains visible with the keyboard open. Selecting,
removing or adjusting an image changes a draft; **Save** applies and persists it
in one replacement. Leaving the editor without saving keeps the prior settings.

Imports accept JPG, PNG and WebP. On Android, iOS and desktop, **Save** copies
the original file unchanged into the app support directory (`wallpaper/`), the
preference keeps only its file name, with no size limit; replacing or removing
it deletes the previous copy. Chat decodes only the pixels the display can show
(the short side at the display's long side), so a large photo stays sharp
without costing frame time. The Web keeps
the image inline in localStorage, so it accepts up to 20 MiB and 40 million
pixels and makes a JPEG copy with a long edge of at most 1920 pixels, reduced
further to fit 256 KiB, using asynchronous browser bitmap decoding and canvas
encoding so the loading indicator keeps animating; transparent pixels are
flattened onto neutral gray, and clearing site data removes it. Images stay on
the device.

Chat draws a centered, aspect-preserving cover image behind its surfaces. The
first-level pages (solo chat, the chat home and Swarm) make everything drawn on
the wallpaper acrylic: headers, sidebars, drawers, banners, home cards,
composers and message bubbles share one 72% theme tint over clipped backdrop
blur, and the composer surface reaches the bottom edge behind the gesture bar.
Those surfaces never overlap, so a page blurs one shared backdrop snapshot
(`BackdropGroup`) instead of one per surface; the drawer, which covers the chat,
and a surface nested in another take their own. Every other page opened from
the app (File System, Quota Usage, Settings, ...) shows the wallpaper image
itself blurred under the same tint and keeps solid content. An empty chat
shows only the wallpaper. Removing the image restores solid surfaces after Save.

## Credentials and agent login

`npm run credential` creates an encrypted `relay.credentials.v1` QR/JSON
envelope containing the backend URL, machine identity, and one revocable device
token. It uses PBKDF2-HMAC-SHA256 (600,000 iterations) and AES-256-GCM. The
passphrase is prompted for interactively and is not saved. Unattended setups can
supply it with `--passphrase` or `RELAY_CREDENTIAL_PASSPHRASE`, at the cost of
exposing it to shell history, the process environment, or a launcher/config file.

Useful commands from `server/`:

```bash
npm run credential
npm run credential -- --url https://relay.example.com
npm run credential -- --list-tokens
npm run credential -- --revoke <token-id>
```

The app can scan a QR on supported mobile platforms or import it by image/file
and pasted JSON. Native clients use platform secure storage. The Web client is
subject to browser-origin storage security, so use a private profile on a
trusted device.

Generate a different credential for each device. **Machine details** (tap the
machine in the drawer or on the home page) lists their token ids, device
metadata, and last-use time. Revoke a token before
deleting its record; revocation also closes the terminal owned by that token.
Generating another credential removes old export files but does not revoke
tokens that were already issued.

Relay reports separate installed, authenticated, and usable state for every
known agent. Claude Code, Codex, and Cursor are signed in on the host with
each CLI's own login (`agent login` for Cursor). OpenCode and Hermes are
experimental. Every credential is created on the backend host. Relay never
logs a CLI in remotely.

Relay reports no login deadline because every supported CLI refreshes its
tokens. Short-lived access-token expiry is not a login deadline. Machine
details shows ready state for authenticated agents. Cursor's CLI binary is
`agent`, not `cursor`.

Stored Codex state distinguishes managed ChatGPT, API-key, external-token, and
host-managed provider modes. An explicit **Recheck** calls `account/read` with
`refreshToken: true` on Relay's shared Codex app-server; a missing account or a
rejected refresh marks Codex as requiring authentication, while a transient
probe failure is reported as a check error and leaves the app's displayed state
in place.
Only normalized auth/status fields leave the backend: account identity and
credential values are discarded. Separately, `server/lib/usage.js` reads the
Claude Code, Codex, and Cursor tokens for quota reporting and can refresh an
expired Claude Code or Codex access token atomically in the CLI's credential
file.

## SSH terminal

**Machine details → Enter SSH** opens an interactive PTY on the backend. It
uses the backend service account's login shell, starts in that account's home
directory, and is presented by the same Flutter terminal emulator on mobile,
Web, and desktop. The colors follow Relay's current Light/Dark theme. Terminal
text uses the bundled `RelayTerminalMono` family, backed by Cascadia Mono, with
system monospace fallbacks for missing glyphs. Keep the bundled family as the
primary font: xterm measures its character grid before painting, and Chromium
can otherwise measure a proportional fallback and produce excessively wide
horizontal cells.

On Android and iOS a key bar below the terminal adds the keys a phone keyboard
lacks: Ctrl, Shift, Esc, Tab, and the four arrows. Ctrl and Shift latch: a lit
modifier applies to the next key, typed on the soft keyboard or tapped on the
bar, and then releases, so Ctrl then `c` sends `^C`; tapping it again cancels.
Esc, Tab, and the arrows send at once. Combinations such as Shift+Tab or
Ctrl+Left are encoded by xterm's keytab, exactly as from a hardware keyboard.

An authenticated `POST /api/terminal/ticket` returns a random, single-use ticket
valid for 30 seconds. The client redeems it at `/api/terminal/connect`; the
long-lived bearer credential is not sent in the WebSocket URL. One token record
maps to one PTY. Returning to Machine details leaves that PTY alive, and the
next Enter SSH reconnects to it; opening it elsewhere replaces the old socket
instead of creating another shell.
Revoking the device token closes the socket and PTY. Revocations made by the
credential CLI are picked up by the terminal heartbeat without a server restart.

Detached PTYs expire after 12 hours and retain up to 2 MB of output in process
memory for replay; terminal transcripts are not written to disk.
Operators can tune these bounds with `TERMINAL_IDLE_TIMEOUT_MS` (60 seconds to 7
days) and `TERMINAL_BUFFER_MAX_BYTES` (64 KB to 16 MB), or select a shell with
`RELAY_TERMINAL_SHELL`. These settings do not make the terminal a sandbox: it
has the full permissions of the backend OS user and bypasses the file API's
denylist and `RELAY_FS_ROOTS`.

## Runtime model

### Agent sessions

No agent is re-spawned per turn. Each keeps a live CLI session that turns are fed
into, the way a terminal session works, so follow-up turns skip the cold start
and cancelling a turn interrupts it instead of ending the conversation. Claude
Code runs one Agent SDK process per conversation; OpenCode, Hermes, and Codex
speak stdio JSON-RPC (`acp` for the first two, `app-server` for Codex), where one
process per agent hosts every chat because each session carries its own workdir.

Every pool is only a cache. The resumable session id in
`server/agent-sessions.json` stays authoritative, so a chat whose process was
closed reloads into the same conversation on its next turn — the same behaviour
as before, just slower for that one turn.

Idle sessions are closed and there is a cap on how many stay live, because these
processes can be resource-intensive. See `RELAY_CLAUDE_*` and `RELAY_AGENT_*`
in `server/.env.example`. Defaults retain up to three Claude processes and four
live JSON-RPC sessions per agent, with a 15-minute idle timeout. Turns past a
cap wait for a slot.

Work an agent starts in the background now outlives the turn that started it,
except on Codex: its sandbox kills each command's process group as the command
returns, so background work there survives only if it detaches into its own
session (`setsid`). A Claude process with background tasks still running
(background subagents, Monitor, background shells) is not closed as idle, and
is evicted for the cap only when no other idle process can make room.

When such work wakes Claude while the chat is idle, the turn it starts is
shown in solo chat as a reply of its own once Claude writes text, queued behind
any waiting turn and stopped by Stop like any other. A turn that only runs tools
stays invisible. Swarm members and the other agents do not surface these turns.

Deleting or clearing a conversation removes Relay's history and stored resume
id, then asks the pooled integration to remove its CLI-side transcript. That
last step is best effort because the external CLI can reject or fail deletion;
inspect the host's CLI state if guaranteed erasure is required. Cursor has no
delete command, so Relay removes that session's directory under
`server/cursor-config/acp-sessions/` itself.

### Workdirs, conversations, and settings

Each device stores its current workdir per backend and sends it in `X-Workdir`. Backend state
then uses two related scopes:

| State | Scope |
|---|---|
| Named conversation, history, running turn, native CLI resume id | `workdir + agent + sessionId` |
| Model, effort, permission, fast mode | `workdir + agent + sessionId` |
| Swarm list | workspace in `X-Workdir` |
| Swarm transcript and member sessions | Swarm id plus its chosen work tree |

An agent context supports up to eight named conversations. `Main` preserves the
legacy scope key and cannot be deleted or renamed. Renaming another session only
changes its label, even during a running turn; its position and the active session
stay the same. Turns in one exact conversation scope
queue; other sessions can continue independently. Devices on the same scope
share backend history and live events. A new session starts from a copy of the
settings of the session it was created from; a session with no settings of its
own (one created before settings were per session) follows Main's until its
first change.

In solo chat, **+ → Attach file** picks one or more files, including during a
running turn. Each file uploads to `<workdir>/.relay/uploads/` with a
`yyyyMMdd-HHmmss-` prefix from the device's local time. Each successful upload
appends its workdir-relative path on a new line in the draft; the user sends the
message when ready. Attachments appear in that repository's git status unless
`.relay/` is ignored.

Above the solo-chat composer, the context usage line shows `<used> / <window>`
in tokens (for example, `42k / 200k`), using the latest reported usage in the
conversation. A new or cleared conversation shows `0 / <window>`; a conversation
with replies but no recorded usage shows `? / <window>`. An unknown window is
shown as `?` until that agent and model has reported one. The backend remembers
the last reported window per agent and model in the generated state file
`server/context-windows.json`, so an empty conversation can show the known limit.
Cursor reports no context usage, so the line is hidden while Cursor is active.

Agent controls are capability-aware:

| Agent | Model | Effort | Permission | Fast | Authentication |
|---|---:|---:|---:|---:|---|
| Claude Code | yes | yes | yes | yes | OAuth |
| Codex | yes | model-specific | yes | yes | active app-server mode: managed ChatGPT, API key, external token, or host-managed provider |
| Cursor | yes | model-specific | yes | yes, models with a fast option | host auth file or `CURSOR_API_KEY` |
| OpenCode | yes | yes | yes | no | host-managed, optional key |
| Hermes | shows the host's configured model; pins | no | yes | no | host-managed key |

Fast mode defaults off, may use more quota or cost more, and is visible only in
the solo-chat composer. Relay sends an explicit Claude `fastMode` setting,
Codex `serviceTier`, or Cursor `fast` option on every turn. Availability still depends on
the selected model, CLI version, account, and provider. Swarm storage can retain
the field, but the current Swarm form exposes only model, effort, and permission.

Claude settings are fixed for the life of its per-conversation SDK process, so
a change restarts that process and resumes the same conversation. OpenCode
and Hermes settings apply over ACP without restarting their shared process.
Cursor applies a model, effort and speed to a whole process, so each distinct
choice runs in a Cursor process of its own (conversations with the same choice
share one), and changing it resumes the conversation in the matching process.
These processes use Relay's own Cursor config directory, `server/cursor-config/`,
so model choices made in Relay never change the host user's `~/.cursor`
defaults; login is still the host's `agent login`. Codex
applies model, effort, and service tier per turn; changing its sandbox reopens
the thread while resuming the same conversation, without respawning the shared
app-server process.

Codex model and reasoning choices come from the installed CLI's structured
catalog and keep each model's advertised order/default. Updating Codex clears
the discovery cache. Cursor's catalog comes from its ACP server
(`cursor/list_available_models`) at backend startup, after a CLI update, and
when the picker opens (at most every ten minutes). Each model offers its own
effort levels and, where it has one, the fast switch; context size and thinking
stay at the model's default. Relay keeps the last list in the generated state
file `server/reported-models.json`; before the first answer, and when Cursor is
not signed in, the picker offers only Auto, which is also the default.
OpenCode's list comes from `opencode models` on the same schedule: its free
models, which change on OpenCode's side, plus every provider configured in the
host's OpenCode (`~/.config/opencode/opencode.json` or `opencode auth login`),
each labelled with its model name over its provider. Before the first answer it
offers `big-pickle`. Hermes' picker shows the one model configured on the host
(`hermes model`), read with `hermes config get model.default` on the same
schedule; it is a label, so Hermes keeps running its configured model. Both are
kept in `server/reported-models.json` too. Local pins may be added in the
gitignored `server/models-extra.json`.

The model page lists main models first and links to the rest from the bottom
of the screen. For Cursor that second page holds every model outside the Cursor
plan's included usage (anything but Auto, Grok and Composer), which bills
prepaid usage from the first request. For Claude Code and Codex it holds legacy
models: older versions of a family, and families with no model in the newest
generation. They stay selectable. The Swarm form offers only main models.

### History, search, and export

Relay keeps raw chat messages in `server/chat-history.json`, capped at the most
recent 200 messages in each conversation or Swarm scope. This file is backend
state, not an encrypted archive, and can contain prompts, agent output, and
sensitive project context. Protect it and any backups with the same care as the
backend account.

In solo chat, settled messages offer **Copy**; agent replies copy the final
answer text. Your own messages also offer **Edit**, which replaces the draft
with that message's text for you to revise and send. Editing leaves stored
history unchanged and sends nothing until you choose to send.

The client can search the current workdir across named sessions and agents, or
limit the search to the current agent. The backend returns at most 50 matches;
the client can jump to and highlight a result. Markdown export covers the
current conversation. Search snippets and exported Markdown pass through
Relay's targeted token-pattern redaction, but that filter is not a general
secret scanner and does not alter the raw stored history.

### Swarms

A Swarm is one canonical transcript above several independent CLI sessions.
Each workspace can store up to 20 Swarms, with up to eight members in each.
When a human message mentions multiple members, Relay snapshots the transcript
once, builds a speaker-labelled delta for each member, and runs those members in
parallel. Each member still serializes against its own private Swarm session.

Members can summon each other. A member's prompt lists the other members and the
`@name` that reaches each, and any of those names in its reply hands them the
floor: the round continues with another wave, snapshotted after the previous
replies so the newly summoned members see them. `RELAY_SWARM_MAX_HOPS` bounds how
many agent-driven waves follow the human's message (default 3; set 0 to keep
summoning human-only), because two members that keep naming each other would
otherwise run — and bill — without end. A member cannot summon itself, and a
turn that failed or was cancelled summons no one.

At creation, a Swarm selects its work tree and per-member model, effort,
permission, nickname, and prompt/persona. The work tree cannot be changed later
because it is part of the keys for the Swarm transcript and each member's
resumable session; changing it would address a different conversation.
Swarms can be cleared, updated, deleted, or saved as reusable JSON templates.
Templates contain the name, member list, and member configuration; they omit the
machine-specific workdir, id, and transcript.

### Quota and notifications

The usage screen reports Claude Code, Codex, and Cursor. It queries each source on its
own (`GET /api/usage?source=claude|codex|cursor`; an unknown source is a 400), so one
card fills in as soon as its source answers. The solo-chat composer also pins
the active agent's remaining quota above the input for Claude Code, Codex, and Cursor; it
reads the same per-source endpoint when the agent changes and after each turn,
at most once a minute per agent, matching the backend's one-minute usage cache.
Cursor reads the host auth file (or exchanges `CURSOR_API_KEY`) and asks Cursor's
dashboard for included usage. An X plan such as Premium is one weekly pool; an
older Cursor plan is two pools, Cursor models and API models. The query does not
spend usage. Cursor's reset does not queue a scheduled message.
Reset detection and
scheduled messages support Claude Code and Codex only. A schedule stores one
prompt per source and workspace for the next detected five-hour reset.

Claude's five-hour window only exists while it runs: once it lapses the usage API
reports no reset time, which the app can only show as unknown. The backend keeps
the window cycling by sending one minimal Claude Code request (one output token)
whenever the window is idle, then sleeping until just after the new reset
moment. It is enabled by default, is billed like an ordinary provider request,
and can consume quota. Set `ENABLE_CLAUDE_KEEPALIVE=false` to turn it off and
accept the unknown state; `CLAUDE_KEEPALIVE_MODEL` overrides the model used for
the ping. Codex quota discovery likewise sends a minimal Responses request to
obtain rate-limit headers and can consume quota. Both usage paths may refresh
the host's OAuth access token.

Notification delivery has three layers:

- Android, iOS, macOS, and Windows can show local notifications while Relay is
  receiving live events; Web can use browser notifications.
- Optional Web Push reaches a subscribed browser after the tab closes.
- Optional FCM reaches configured Android builds after the app is killed.

Linux desktop currently falls back to an in-app message. Fully killed iOS apps
do not have a configured offline push channel in this repository.

## API map

All HTTP `/api/*` endpoints require the imported bearer token. The terminal
WebSocket upgrade requires the short-lived ticket created by its HTTP endpoint.

- Metadata/auth: health, client auth status, agents and their auth state, agent
  options/settings/version/update, diagnostics, device tokens, and shared events.
- Chat: chat, cancellation, history, history search/export, and clear session.
- Named sessions: list/create, set active, rename (`POST /api/sessions/rename`),
  and delete.
- Files/workdir: current workdir, recent workdirs with chat history, absolute
  directory browse, upload, and download.
- Swarms: list/create, update members, delete, history, clear, chat, and cancel.
- Quota: usage (all sources or one), schedules, schedule replacement, and
  cancellation.
- Push: browser subscription/config and FCM device registration.
- SSH terminal: authenticated ticket creation plus the WebSocket PTY transport.

The route implementations in `server/routes/` are the source of truth when an
endpoint changes.

## Development and builds

### Backend and Web

```bash
cd server
npm install
cp .env.example .env
npm start
```

On Linux, `node-pty` compiles a native addon during `npm install`; install
Python 3, `make`, and a C++ compiler first (for example `build-essential` on
Debian/Ubuntu; `./scripts/install/linux/setup.sh` installs them there when
missing). macOS and Windows use the package's supported prebuilt binaries
when available. Unix hosts also need `zip` for directory downloads.

`server/package.json` allows node-pty's install scripts through npm 12's
`allowScripts` policy, so `npm install` and `npm ci` build it without manual
approval. npm 10 ignores this field. Check the installed addon with
`node -e "require('node-pty')"` from `server/`; if it fails, run
`npm rebuild node-pty`. The backend setup adapters check that it loads and repair
an incomplete installation.

To let the backend serve the Flutter Web client:

```bash
(cd app/shell && flutter pub get && flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn)
npm --prefix server start
```

The server serves `app/shell/build/web` when present, unless
`RELAY_SERVE_WEB=0`. CanvasKit is bundled locally and the service worker is
disabled to keep the self-hosted client current.

`scripts/dev/restart_backend.sh` restarts only the PM2 backend: it
syntax-checks the backend JavaScript (`SKIP_CHECK=1` skips this), restarts or
recreates `relay-server`, and waits until the port answers.
`scripts/dev/build_flow.sh` also analyzes and tests the client, rebuilds Web
and builds a debug APK.

### Windows backend release bundle

Build the backend bundle on Windows x64 using a complete Node.js distribution
(including npm and its license), Git, Flutter, the system .NET Framework 4.x
C# compiler and access to the npm registry:

```powershell
.\scripts\release\package_windows_backend.ps1
# Optional: select a different installed runtime or output directory.
.\scripts\release\package_windows_backend.ps1 -NodeDirectory C:\node -OutputDirectory C:\releases
# Reuse a Web build made from the same source instead of rebuilding it.
.\scripts\release\package_windows_backend.ps1 -SkipWebBuild
```

The script writes `build/release/relay-backend-windows-x64-v<VERSION>.zip` and a
matching `.sha256`, taking the version from `server/package.json`. It refuses
to overwrite an existing ZIP. A fresh staging directory copies only allowed,
tracked backend sources, installs production dependencies with `npm ci`, and
audits the application tree before compression. It never copies deployment
state or the checkout's `node_modules`. Staging directories stay under the
output directory for inspection. The bundle manifest records the source HEAD,
Node version, architecture, and lockfile hash; source files include current
working-tree edits. Review those edits before publishing a bundle.

The ZIP carries its own Node.js/npm distribution and preserves dependency
licenses, including Windows `node-pty` binaries. The Windows adapters prefer
`runtime/node` when present; a source checkout continues using Node on PATH.
The bundle provides setup/start/stop/status/uninstall and credential `.cmd`
entry points, with the same state paths and login Scheduled Task as the source
installation. `Setup.exe` is a Windows Forms UI built with the system .NET
Framework compiler, without a downloaded GUI runtime. It and the console menu
share `scripts/install/windows/lib/setup.ps1`: install, reinstall, uninstall, status,
agent installation and token create/delete/list/re-show. Passwords reach the
worker through stdin and the existing credential generator through its
environment, never command arguments or temporary request files. The bundle
includes `app/shell/build/web`; Node serves it alongside the API, without another Web
server. Setup enables it by default and can turn it off. Tunnel modes download
missing `cloudflared` into `runtime/tools`; selected CLIs use official Windows
installers and require the user to sign in afterward. Uninstall can remove Web
and the bundle-owned tunnel tool and optionally delete a named Cloudflare
tunnel, while retaining backend state and other host software. Keep the
extracted directory fixed, and follow the bundled
README when migrating a deployment to a new directory.

### Desktop clients

Desktop runner projects exist for Windows, macOS, and Linux, but each target
must be built on its own operating system. Windows and Ubuntu release builds
have been exercised; broader Linux distribution and macOS release validation
is still needed before advertising them as packaged releases.

```bash
cd app/shell
flutter run -d windows       # or macos / linux
flutter build windows --release
flutter build linux --release --no-pub
./build/linux/x64/release/bundle/relay
```

Build prerequisites:

- Windows: Visual Studio with Desktop development with C++, Windows SDK, CMake,
  and Flutter. Use an ASCII-only repository path. The repository already adds
  the MSVC coroutine compatibility define needed by the notifications plugin.
- macOS: Xcode, command-line tools, CocoaPods, and Flutter desktop enabled.
- Linux: clang, CMake, Ninja, pkg-config, GTK development packages,
  `libsecret-1-dev`, and a keyring such as GNOME Keyring. On Ubuntu:
  `sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev liblzma-dev`.
  The desktop session also needs an XDG desktop portal for file picking.

Typical artifacts, under `app/shell/`, are `build/windows/x64/runner/Release/`,
`build/macos/Build/Products/Release/Relay.app`, and
`build/linux/x64/release/bundle/`. Keep the entire Linux bundle together when
moving it. CI also offers an Ubuntu 22.04-built Linux archive as a workflow
artifact. Store signing and macOS notarization are not configured.

### Android release signing

Android release builds are signed with a keystore described by the gitignored
`app/shell/android/key.properties`; without that file a release build fails rather than
falling back to debug signing. Debug builds need no key. Create the keystore
once, outside the repository, and back it up: every later release must use the
same key, or installed apps cannot be updated in place.

```bash
keytool -genkeypair -v -keystore ~/relay-release.jks -storetype PKCS12 \
  -keyalg RSA -keysize 2048 -validity 10000 -alias relay
```

In `app/shell/android/`, copy `key.properties.example` to `key.properties`, set
`storeFile` to the keystore's absolute path, and fill in both passwords; with a
PKCS12 keystore, `keyPassword` is the same as `storePassword`. Then
`flutter build apk --release` in `app/shell` produces a release-signed APK.

### Release assets

The `CI` workflow checks pull requests on Linux, Windows and macOS. It analyzes
and tests the Flutter client, builds Web, an Android debug APK, a Windows
desktop client and an unsigned iOS client, tests the backend on Node 22 and 24,
and checks the versions and local documentation links. The `CI complete` check
must pass before a pull request can be merged into `main`. Dependabot reports
vulnerabilities and proposes grouped weekly dependency updates.
CI also blocks high and critical vulnerabilities in production npm dependencies.
Changes to the release or install scripts also build and audit the release
bundles on the pull request without creating a release.

To prepare a release after the changes merge and `CI complete` passes on
`main`, run **Prepare release draft** from the repository's Actions tab, choosing
`main`. It builds the source backend and Windows bundles, verifies their
contents and checksums, and creates a draft for that exact commit. It refuses
an existing version tag. The draft is marked incomplete until the Android APK
is signed locally; signing keys must not be uploaded to GitHub.
From a terminal, the same workflow starts with
`gh workflow run release.yml --ref main`.

On the machine holding the Relay Android release key, check out the draft's
commit, set `ANDROID_HOME` and authenticate the GitHub CLI, then run
`./scripts/release/add_signed_android.sh`. It verifies
the draft and source commit, signs in a clean temporary checkout, checks the
APK's version and release certificate, verifies the other downloads, uploads
the APK and replaces `SHA256SUMS`. The signing configuration must use an
absolute keystore path. The clean checkout excludes local
`google-services.json`, so the public APK has no Firebase configuration;
deployments using Android FCM must build their own configured client. Review
the completed draft on GitHub before publishing it.
For an unsigned iOS IPA, run **iOS build** manually from the Actions tab; the
downloaded artifact must be signed before installation. It can also be started
with `gh workflow run ios.yml --ref main`.

A GitHub release `v<VERSION>` carries:

- `relay-android-v<VERSION>.apk` — `app/shell/build/app/outputs/flutter-apk/app-release.apk`;
- `install.sh` — `scripts/install/linux/install.sh`, the Linux one-line installer
  (`curl -fsSL https://github.com/elin66alpha/Relay/releases/latest/download/install.sh | bash`).
  It downloads this release's setup bundle and `SHA256SUMS`, so upload it with
  them;
- `relay-backend-setup-v<VERSION>.tar.gz` — the committed backend sources and
  service adapters, without tests, dependencies, or deployment state, plus the
  compiled Web client in `app/shell/build/web`. `./scripts/release/package_backend.sh` builds the
  Web client and writes it with a `.sha256` to `build/release/`; it refuses a
  tree with uncommitted tracked changes.
- `relay-windows-x64-v<VERSION>.zip` — the Windows desktop client
  (`app/shell/build/windows/x64/runner/Release/`);
- `relay-backend-windows-x64-v<VERSION>.zip` — see
  [Windows backend release bundle](#windows-backend-release-bundle);
- `SHA256SUMS` — `sha256sum` of every asset above.

## Configuration

### Refreshing application icons

`app/core/assets/icon.png` is the transparent master. After replacing it, run
`dart --packages=.dart_tool/package_config.json ../../scripts/dev/generate_icons.dart`
from `app/shell` (after `flutter pub get`) to export the
Android, iOS, macOS, Web, and Windows assets into the shell. The Windows ICO includes 16, 24,
32, 48, 64, 128, and 256 pixel images. iOS and maskable Web exports use an opaque
navy background; other exports retain the master's transparency. Rebuild each
client to embed its new assets.

### Backend settings

`server/.env.example` documents supported deployment settings. The most useful
groups are:

- identity/network: `PORT`, `HOST`, `PUBLIC_BASE_URL`, tunnel variables;
- execution: `RELAY_DEFAULT_DIR`, `AGENT_TIMEOUT_MS`, `PROMPT_MAX_BYTES`,
  `RELAY_MODEL_DISCOVERY`, `CODEX_HOME`, `RELAY_TERMINAL_SHELL`, and terminal
  idle/buffer limits;
- agent sessions: `RELAY_CLAUDE_IDLE_MS`, `RELAY_CLAUDE_MAX_LIVE`,
  `RELAY_CLAUDE_BIN`, `RELAY_AGENT_IDLE_MS`, `RELAY_AGENT_MAX_SESSIONS`;
- Swarms: `RELAY_SWARM_MAX_HOPS`;
- security/files: `CORS_ALLOW_ORIGIN`, `RELAY_FS_ROOTS`, upload/download caps;
- usage: quota watch, poll interval, HTTP/probe timeouts and backoff;
- offline push: VAPID keys and `FCM_SERVICE_ACCOUNT_FILE`.

The default workdir for a new device is `~/Relay`;
after first use, each device persists its own selection.
