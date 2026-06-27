# Relay Handbook

Everything beyond the README: deploying to production, building the native
desktop apps, and how the Swarm (multi-agent group chat) works under the hood.

[Security model](../SECURITY.md) ·
[Production deployment](#production-deployment) ·
[Desktop builds](#desktop-builds) ·
[How Swarm works](#how-swarm-works)

---

## Production deployment

Quick Tunnel is great for trials, but a real deployment wants a stable URL, a
small attack surface, and a clear recovery path. Relay runs behind a named
Cloudflare Tunnel or directly on a public host.

If you are setting up Relay for the first time, the app's empty credential
screen includes a **Deploy backend** guide with the same five-step setup flow as
the README: prepare a backend machine, run the OS setup script, choose the
network mode, generate an encrypted credential, then import it by scan, image
upload, or paste. This handbook is the follow-up for stable public deployment.

### Recommended shape

- **HTTPS only.** Terminate TLS at Cloudflare (named Tunnel) or at a reverse
  proxy such as Nginx or Caddy (direct mode). If `PUBLIC_BASE_URL` is `http://`
  to a routable host, the server prints a loud startup warning: the device token
  then travels in cleartext and anyone on the path can steal it (it is warn-only
  — `localhost` and `https://` are exempt, and it never blocks startup).
- **Stay on localhost.** Prefer `HOST=127.0.0.1` with the proxy/tunnel in front
  over `HOST=0.0.0.0`, unless the proxy runs on another host.
- **Rate limiting is built in.** `/api` is capped per client IP (600/min; the
  SSE stream and file transfers are exempt) and wrong-token attempts are
  throttled to 15/min, answering `429`. The limiter reads the real client IP
  from `X-Forwarded-For` via `trust proxy` set to `loopback`, so keep the
  tunnel/proxy on localhost and let it forward that header.
- **Pin the URL.** Set `PUBLIC_BASE_URL` to the exact address users import (e.g.
  `https://agent.example.com`) and regenerate credentials after changing it.
- **One credential per device.** Revoke and then delete old device tokens
  instead of sharing one long-lived token.
- **Keep secrets out of git:** `server/.env`, `server/tokens.json`, and
  `server/credentials/` hold deployment identity, access tokens, and encrypted
  credential exports.

### Reverse proxy checklist

- Forward `GET`/`POST` and the long-lived `GET /api/events`; **disable
  buffering** for `/api/events` and streaming `/api/chat` responses.
- Pass `X-Forwarded-For` (Cloudflare and most proxies do by default) so the
  rate limiter keys on the real client IP, not the proxy's loopback address.
- Keep proxy timeouts longer than the agent timeout (default 60 minutes).
- Upload/download caps default to 100 MB / 300 MB (`UPLOAD_MAX_BYTES` /
  `DOWNLOAD_MAX_BYTES`); tune only if the proxy and network can handle them.
- Narrow CORS with `CORS_ALLOW_ORIGIN`. The device token is the real API gate,
  but a tight origin reduces accidental exposure.
- Optionally confine the file API to an allowlist with `RELAY_FS_ROOTS`. Even
  without it, Relay refuses to serve `tokens.json`, `.env`, `credentials/`,
  `~/.ssh`, and the CLI auth files, so a leaked token cannot mint new
  credentials or steal host keys through the file API.

### Direct public host

- Run the Node process behind a service manager (PM2, systemd, LaunchAgent, or a
  Windows Scheduled Task) as a **non-root** user that owns only the intended
  work directories.
- Restrict the inbound firewall to the proxy port (normally 443) and keep the
  backend port private.
- After deploys, verify with `GET /api/diagnostics` from an authenticated app
  session: public URL, token state, CLI availability, active requests, storage
  files, and workdir access.

### After any change

- Changed `PUBLIC_BASE_URL`? Re-run the credential script and re-import in the
  app.
- Rotated/revoked/deleted tokens? Confirm old devices fail and current ones
  still pass `GET /api/health`.
- The local backend should always still answer on `http://127.0.0.1:<PORT>` from
  the backend host — that is your rollback path for any tunnel/proxy change.

---

## Desktop builds

Relay's client is a **native Flutter app** — there is no Electron or web wrapper.
The same `lib/` code runs on mobile, Web, and all three desktops; `windows/`,
`macos/`, and `linux/` are the standard Flutter desktop runner projects.

**Each OS builds its own target — desktop binaries cannot be cross-compiled.**

| Target  | Build host required                       | From a Linux box? |
|---------|-------------------------------------------|-------------------|
| Windows | Windows + Visual Studio (VS 2022 or 2026) | No                |
| macOS   | macOS + Xcode + CocoaPods                 | No                |
| Linux   | Linux (clang / cmake / ninja / GTK)       | Yes               |

### Prerequisites

- **Windows:** VS 2022/2026 with the *"Desktop development with C++"* workload
  (MSVC, Windows 10/11 SDK, CMake); Flutter on PATH.
- **macOS:** Xcode + command line tools, CocoaPods
  (`sudo gem install cocoapods`); `flutter config --enable-macos-desktop`.
- **Linux:** `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev
  liblzma-dev`, plus `libsecret-1-0` and a keyring (e.g. `gnome-keyring`) for
  `flutter_secure_storage`.

### Build

```bash
flutter pub get
flutter run -d windows            # or: -d macos / -d linux
flutter build windows --release   # or: macos / linux
```

Artifacts: Windows `build/windows/x64/runner/Release/` (a portable folder — zip
to share); macOS `build/macos/Build/Products/Release/Relay.app`; Linux
`build/linux/x64/release/bundle/`.

### Windows build gotchas

Two toolchain quirks (not Relay bugs) can block a Windows build:

1. **A non-ASCII (CJK) repo path** breaks the toolchain — `flutter analyze`
   crashes in its LSP channel and `flutter build windows` fails to read
   `app.dill` (the path shows mojibake). Fix: build from an **ASCII-only path**
   (e.g. `D:\code\Relay`). For analysis alone, `dart analyze` avoids the failing
   LSP channel.
2. **VS 2026 MSVC (14.51)** turns the deprecated `<experimental/coroutine>`
   header into a hard error, which `flutter_local_notifications_windows` still
   includes. Silence it for the whole build:

   ```powershell
   $env:CL = "/D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS"
   flutter build windows --release
   ```

   VS 2022 does not need this. If you moved the repo to dodge issue 1, run
   `flutter clean` first so stale plugin symlinks don't trip
   `PathExistsException`.

### Connecting on desktop

- **No camera scanner on desktop** (`mobile_scanner` is mobile/macOS only): the
  credential screen offers **Upload QR image** and **Paste credential** instead.
  Generate the credential on the backend, then upload the PNG or paste the
  payload and enter the passphrase.
- Quick Tunnel backends use the same `https://*.trycloudflare.com` URL as
  mobile/Web; regenerate the QR after it rotates.
- Plain `http://<ip>:port` works; macOS allows the cleartext request via
  `NSAllowsLocalNetworking`.

### Platform notes

- **Notifications:** native on Android/iOS/macOS/Windows while the app is alive
  on SSE; Linux falls back to an in-app system message.
- **Secure storage:** Windows Credential Manager / macOS Keychain / Linux
  libsecret (needs a keyring daemon).
- **macOS sandbox:** both entitlement files include
  `com.apple.security.network.client`, required to reach the backend.

### Signing & packaging

- **macOS:** an unsigned `.app` runs but Gatekeeper warns on first launch —
  right-click → **Open**, or `xattr -dr com.apple.quarantine Relay.app`.
  Distribution needs an Apple **Developer ID** signature + **notarization**.
  Bundle id: `dev.relay.app`.
- **Windows:** the `Release/` folder is portable (the target needs the usually
  present VC++ runtime). MSIX / Inno Setup / NSIS installers are possible but
  not set up in-repo.

---

## How Swarm works

A **Swarm** (蜂群) is one chat box, one human, and several AI agents sharing a
single transcript. You summon members with `@mentions`; mention several in one
message and they answer **in parallel**, each from the same conversation
snapshot. (In the code, routes, and storage the feature is called `group`.)

### The core idea: orchestration, not shared memory

Each CLI agent keeps its **own private memory** (`claude --resume`, Codex/Agy
resume, etc.) and these cannot see each other. So a Swarm is an orchestration
layer on top of independent per-agent sessions, not a shared brain:

- The backend stores **one canonical group transcript**.
- On an agent's turn, the orchestrator feeds it only the **delta** since it last
  spoke — each line labeled with its speaker — the agent replies, and the reply
  is appended to the transcript with attribution. The agent's own resumable
  session already holds everything else.

"Who summoned whom" is metadata the orchestrator records, not a native
capability of the agents, so the existing single-agent runners are reused
unchanged.

### A round, end to end

1. **Human posts a message.** `@mentions` select who runs this round; a message
   with no mention is just recorded.
2. **Snapshot.** The transcript is snapshotted once; every summoned member builds
   its prompt from that same snapshot.
3. **Delta prompt.** Each member receives only what is new since it last spoke,
   speaker-labeled, plus a marker that it is now its turn (byte-bounded so it
   never exceeds the argv cap).
4. **Run in parallel.** Members run concurrently and stream over SSE. The group
   is busy for the round, but each member also serializes against its own private
   session so its CLI memory stays coherent.
5. **Append + attribute.** Each reply lands on the transcript with `author` and
   `summonedBy`; placeholders keep ordering stable even when replies finish out
   of order.
6. **Idle.** When all members settle, the Swarm waits for the next human message.

### What you can configure

Each Swarm pins its own **work tree** (a directory chosen at creation — e.g. a
git worktree), and each member gets its own **model / effort / permission** plus
an optional **nickname and per-member prompt** (persona). That is enough to build
heterogeneous roles — a read-only "reviewer" alongside a write-enabled "doer" on
different models — with no extra machinery.

### Where it lives

- **Backend:** `server/lib/groups.js` (config), `server/lib/group-turn.js` (pure
  `parseMentions` / `deltaSince` / `buildGroupPrompt`, unit-tested), and
  `server/routes/group.js` (endpoints + the round orchestrator).
- **Client:** `lib/core/models/group.dart` and
  `lib/features/chat/group_chat_{controller,screen}.dart`; the left drawer lists
  every Swarm in the workspace as always-visible sub-entries.
- **Endpoints** (auth + `X-Workdir`): `GET`/`POST /api/groups`,
  `POST /api/groups/members`, `POST /api/groups/delete`,
  `GET /api/group/history`, `POST /api/group/clear`, and `POST /api/group/chat`
  (+ `/cancel`).

### Limits and trade-offs

- **Prompt size.** Prompts ride to the CLI as a single argv token (capped by
  `PROMPT_MAX_BYTES`, default 100 KB). Delta injection keeps each turn small; a
  very large delta must still be bounded before it hits the cap.
- **Cost.** One message can fan out into several concurrent agent turns,
  multiplying token spend across accounts. The quota watch tracks usage.
- **Divergent memory.** Members only know what their injected deltas told them,
  so their private memories diverge by design — which is why consistent,
  speaker-labeled deltas matter.
- **Out of scope (v1):** agent-initiated summon chains (`@agent` emitted by an
  agent) and facilitator / round-robin auto turn-taking.
