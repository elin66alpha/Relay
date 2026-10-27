<div align="center">

# Relay

**Run AI coding agents on your machine. Control them from any screen.**

A private, self-hosted remote cockpit for Claude Code, Codex, Cursor, OpenCode, and Hermes.

![Flutter client](https://img.shields.io/badge/client-Flutter-02569B?logo=flutter&logoColor=white)
![Node.js backend](https://img.shields.io/badge/backend-Node.js_18%2B-339933?logo=node.js&logoColor=white)
![Self-hosted](https://img.shields.io/badge/deployment-self--hosted-5B5BD6)
![MIT License](https://img.shields.io/badge/license-MIT-2F855A)

[中文](README.zh-CN.md) · [Install a backend](backends/README.md) ·
[Security](SECURITY.md) · [Handbook](docs/handbook.md)

</div>

<a href="assets/screenshots/relay-overview-web.png">
  <img src="assets/screenshots/relay-overview-web.png" alt="Relay home screen in the dark theme with a wallpaper, showing the current machine and workspace beside the agent and Swarm drawer" width="100%">
</a>

Relay leaves your source code, shell access, and CLI credentials on the computer
you control. Its Flutter client connects from phone, Web, or desktop to a small
Node.js backend running beside your projects—there is no Relay cloud account and
no hosted middleman.

<table>
  <tr>
    <td width="33%" align="center">🖥️<br><strong>Runs where your code lives</strong><br>Your agents and projects stay on your backend machine.</td>
    <td width="33%" align="center">📱<br><strong>One client, every screen</strong><br>Use the same interface on mobile, Web, and desktop.</td>
    <td width="33%" align="center">🔐<br><strong>Private by design</strong><br>Import an encrypted, revocable credential for each device.</td>
  </tr>
</table>

## See Relay in 60 seconds

### Keep real coding sessions within reach

Stream replies, cancel a turn, search history, export Markdown, and switch away
while work continues. Each `workdir + agent` context supports up to eight named,
resumable conversations.

**Settings → Wallpaper** opens a separate editor for one device-local wallpaper
shared across all agent chats, Swarms and the chat home. Drag the single slider
to preview the current theme's image opacity, then select **Save** to apply.
Light/dark defaults are 80%/20%. Apps keep the original image at full
resolution; the Web stores a compressed copy. Chat panels, message bubbles and
every other page share one acrylic surface over the centered, filling image;
two fields below the slider set its blur (0-30, default 6) and tint (0-100%,
default 55%) for both themes.

<a href="assets/screenshots/relay-chat-web.png">
  <img src="assets/screenshots/relay-chat-web.png" alt="A persistent Claude Code conversation with named sessions, quota and context usage in the Relay Web client" width="100%">
</a>

### Chat, coordinate, and manage files from mobile

<table>
  <tr>
    <td width="33%" align="center"><a href="assets/screenshots/relay-chat-mobile.png"><img src="assets/screenshots/relay-chat-mobile.png" alt="Relay agent chat on mobile" width="100%"></a></td>
    <td width="33%" align="center"><a href="assets/screenshots/relay-swarm-mobile.png"><img src="assets/screenshots/relay-swarm-mobile.png" alt="Relay multi-agent Swarm on mobile" width="100%"></a></td>
    <td width="33%" align="center"><a href="assets/screenshots/relay-files-mobile.png"><img src="assets/screenshots/relay-files-mobile.png" alt="Relay remote file browser on mobile" width="100%"></a></td>
  </tr>
  <tr>
    <td align="center"><strong>Persistent chat</strong><br>Follow a long-running agent session from anywhere.</td>
    <td align="center"><strong>Swarms</strong><br>Let specialized agents work in one shared transcript.</td>
    <td align="center"><strong>Remote files</strong><br>Browse, upload, download, and change the active work tree.</td>
  </tr>
</table>

<sub>These screenshots use the dark theme with a wallpaper set in Settings → Wallpaper. They were captured in Chromium against an isolated demo backend and contain no production credentials or project data.</sub>

## How it fits together

```mermaid
flowchart LR
    C["Flutter client<br/>Phone · Web · Desktop"]
    R["Relay backend<br/>Node.js on your machine"]
    A["Persistent agent sessions<br/>Claude · Codex · Cursor · OpenCode · Hermes"]
    F["Projects and files"]
    T["Resumable PTY shell"]

    C -->|"authenticated HTTP + SSE"| R
    R -->|"local CLI protocols"| A
    R -->|"filesystem policy"| F
    C -. "single-use WebSocket ticket" .-> T
    R --> T
```

The active workdir belongs to each client and is sent on every request. A
conversation is scoped by `workdir + agent + session`, so unrelated sessions
can run concurrently without sharing a global backend directory.

## What you can do

| | Capability | What it gives you |
|---|---|---|
| 💬 | **Live, persistent chat** | Streaming replies, cancellation, named sessions (rename any except Main), cross-device history, search, and Markdown export. Copy messages or use Edit on your own message to put its text back in the draft. Replies Claude starts on its own, such as when a background task finishes, appear as messages of their own. |
| 📎 | **Chat attachments and context** | Attach files to upload them to the workspace and add their paths to the draft. Above the solo-chat composer, see context tokens as `<used> / <window>`; `?` means unknown. |
| 🐝 | **Multi-agent Swarms** | Shared transcripts, per-member roles and controls, parallel waves, bounded `@mention` handoffs, and reusable JSON templates. |
| 🎛️ | **Agent controls** | Model, reasoning effort, permission tier, install/auth status, on-demand Codex credential verification, and Fast mode for Claude/Codex/Cursor. The model page lists main models first; older Claude/Codex models and Cursor models outside its plan sit on a second page. OpenCode lists what the host's OpenCode offers, including providers configured there; Hermes shows its configured model. |
| 📁 | **Files and terminal** | Allowed-path browsing, read-only UTF-8 text previews (first 512 KiB, syntax highlighting for supported code), uploads, downloads, zipped folders, workdir switching, and one resumable PTY per device credential. |
| 📊 | **Quota workflows** | Claude/Codex/Cursor usage views, plus one queued prompt for the next detected Claude or Codex five-hour reset. |
| 🔔 | **Notifications** | In-app/browser alerts, with optional Web Push and Android FCM for configured deployments. |
| 🎨 | **Appearance and updates** | Light/dark theme, font size, a device-local wallpaper, What's new on Home, and Settings → About → Check for updates against GitHub Releases (it reports, never downloads). |

Claude Code, Codex, and Cursor are signed in on the backend host with each
CLI's own login. OpenCode and Hermes are experimental, host-managed
integrations. Relay never logs an agent in for you.

## Quick start

### 1. Prepare the backend machine

Install Node.js 18+ and at least one supported CLI on Linux, macOS, or Windows.
Claude, Codex, and Cursor must already be logged in on that host (`agent login`
for Cursor); OpenCode and Hermes use the provider configuration managed there,
and Relay lists the models that configuration provides.

Windows x64 users can download `relay-backend-windows-x64-v0.1.8.zip` from
[release 0.1.8](https://github.com/elin66alpha/Relay/releases/tag/v0.1.8), extract
it, and run `.\setup.cmd`. This backend bundle includes Node.js and production
dependencies; install and authenticate your agent CLIs separately. The asset
`relay-windows-x64-v0.1.8.zip` is the desktop client.

Run the setup command for your backend OS from the repository root:

| Backend OS | Setup command |
|---|---|
| Linux | `./backends/linux/setup.sh` |
| macOS | `./backends/macos/setup.sh` |
| Windows PowerShell | `.\backends\windows\setup.ps1` |

The installer walks through direct access, a named Cloudflare Tunnel, or a
temporary Quick Tunnel. Use HTTPS before exposing a direct deployment publicly.
Linux also needs PM2 and the native tools listed in the
[backend requirements](backends/README.md#requirements); Unix hosts need `zip`
for folder downloads. On Debian and Ubuntu, the Linux installer offers to
install any of these, and Node.js itself, when they are missing.

### 2. Import an encrypted device credential

Setup prints an encrypted QR code and writes `.relay.png` / `.relay.json` files
under `server/credentials/`. Import one by camera, image/file, or pasted JSON,
then enter its passphrase. Camera scanning is mobile-only; every client supports
file or pasted-JSON import. Generate a separate revocable credential for each
device.

### 3. Pick a project and start working

Choose the backend, set the workdir, and open an agent conversation or Swarm.
Home shows the current machine, current workspace, and up to three recent
workspaces. Tap the machine for CLI status checks, device tokens, and Enter SSH.
In the Android and iOS apps, swipe right anywhere in a chat to open the drawer.
Use File system → Set as work path to select the project before sending a task.
Home → Tutorial includes a detailed guide to sessions, controls, Swarms, files,
and the mobile terminal key bar.
For service commands, networking details, and platform notes, continue with the
[backend guide](backends/README.md).

## Security boundary

- Every HTTP API route requires a revocable bearer token; failed attempts are
  rate-limited.
- Credential exports use PBKDF2-HMAC-SHA256 and AES-256-GCM.
- The terminal exchanges that bearer token for a short-lived, single-use
  WebSocket ticket; the long-lived token never appears in the socket URL.
- The file API denies known Relay, SSH, Claude, Codex, and Cursor secret paths,
  plus the FCM service-account key, and can be restricted further with
  `RELAY_FS_ROOTS`.
- Quota reporting may read and refresh host OAuth files, but token values never
  reach the Relay API or client.

> [!IMPORTANT]
> Relay is not a sandbox. Agent and terminal processes have the permissions of
> the backend OS user. Run it as a restricted non-root user, terminate TLS for
> public deployments, and read [SECURITY.md](SECURITY.md) plus the
> [production checklist](docs/handbook.md#production-deployment) first.

## Development

```bash
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
npm --prefix server install
npm --prefix server test
```

Run the client with `flutter run`. To serve a self-hosted Web build:

```bash
flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn
npm --prefix server start
```

The Web flags intentionally disable the service worker and bundle CanvasKit
locally. Windows release builds have been exercised; macOS/Linux desktop
packaging and secure-storage validation are less mature. Android release builds
need a signing key; see
[Android release signing](docs/handbook.md#android-release-signing). See the
[development handbook](docs/handbook.md#development-and-builds).

```text
Relay/
├── lib/          shared Flutter client
├── server/       Node.js backend and tests
├── backends/     OS-specific install/service adapters
├── docs/         operations and architecture handbook
├── scripts/      development and deployment helpers
└── test/         Flutter tests
```

Contributors and coding agents should read [AGENTS.md](AGENTS.md). Release
history is in [CHANGELOG.md](CHANGELOG.md), and Relay is released under the
[MIT License](LICENSE).
