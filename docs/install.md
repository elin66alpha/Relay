# Backend setup

[中文](install.zh-CN.md) · [Deployment handbook](handbook.md#production-deployment)

Relay uses the same Node.js server and HTTP/SSE API on every backend host. The
scripts in `scripts/install/` only adapt dependency setup, process management, logs, and optional
Cloudflare Tunnel startup to each operating system.

## Requirements

- Node.js 22 or newer.
- At least one supported CLI installed on the backend: Claude Code, Codex,
  Cursor (the `agent` CLI, signed in with `agent login`), OpenCode, or Hermes.
- Every CLI must be authenticated or configured on the backend host itself.
  Relay reports status but does not perform OAuth login or collect provider
  keys.
- Unix hosts need `zip` for directory downloads. Linux setup also needs PM2,
  Python 3, `make`, and a C++ compiler for the terminal PTY dependency.
- `cloudflared` is required only for named or Quick Tunnel mode.
- On Debian and Ubuntu, Linux setup checks all of the above except the agent
  CLIs, including the Node.js version, and after one confirmation installs
  what is missing with `sudo apt-get`: Node.js 24 from NodeSource when Node.js
  is missing or older than 22, and `cloudflared` from Cloudflare's release
  `.deb` when a tunnel mode needs it. Run it as the user who will run Relay,
  not with `sudo`.

## Install

On Linux, one command downloads the latest release, verifies it against the
release's `SHA256SUMS`, unpacks it into `~/relay` (asked at the prompt, or
`RELAY_DIR`) and runs setup. Running it again upgrades the code in place,
keeps `server/.env`, tokens, chats and settings, and restarts the backend.
`RELAY_VERSION=<VERSION>` installs a specific release.

```bash
curl -fsSL https://github.com/elin66alpha/Relay/releases/latest/download/install.sh | bash
```

From a copy of the repository, run one command from its root:

| Backend OS | Command | Service manager |
|---|---|---|
| Linux | `./scripts/install/linux/setup.sh` | PM2 |
| macOS | `./scripts/install/macos/setup.sh` | per-user LaunchAgents |
| Windows | `.\scripts\install\windows\setup.ps1` | per-user Scheduled Task |

The setup script creates `server/.env` when needed, installs server packages,
configures the selected network mode, starts the service, and runs the
credential generator. Import the generated `.relay.png` or `.relay.json` in the
app and enter the passphrase you chose.

On Linux, `setup.sh` opens a menu: install, reinstall (keeps tokens, chats and
settings), uninstall, service status (address, tunnel hostnames, Web client,
agent install and sign-in state, tokens), install agent CLIs, and create,
delete, list or re-show a device token. Installing agent CLIs lists Claude Code,
Codex, Cursor, OpenCode and Hermes with their install state, looking where the
backend does (PATH, `~/.local/bin`, `~/.opencode/bin`), installs the ones you
pick with each CLI's official installer (`npm install -g @openai/codex` for
Codex), and prints their login commands; Relay never signs a CLI in. Install
runs the same step. Re-showing reuses the token and asks for a new QR password, since
the old one is not stored. Install and reinstall ask whether to serve the Web
client at the backend address (default yes).

The source setup package (`relay-backend-setup-v<VERSION>.tar.gz`) includes
the compiled Web client, in `app/shell/build/web`; the backend serves it at `/`
unless `server/.env` sets `RELAY_SERVE_WEB=0`. The API under `/api` always requires a
device token. The Windows backend ZIP includes the same compiled Web client:

- Linux and Windows setup ask whether to serve it; uninstall removes it while
  retaining backend state. Windows serves Web and API in one Node.js process,
  without a separate Web server.
- macOS setup serves a bundled Web client automatically; set
  `RELAY_SERVE_WEB=0` in `server/.env` and restart to turn it off.
- A source checkout has it only after `flutter build web`.

### Network modes

1. **Direct:** use your own reachable address. The server binds to `0.0.0.0`;
   put HTTPS in front before exposing it publicly.
2. **Named Cloudflare Tunnel:** use a stable hostname in a Cloudflare zone. The
   server stays on `127.0.0.1`.
3. **Cloudflare Quick Tunnel:** useful for a trial. The generated
   `trycloudflare.com` URL may change after restart, so regenerate and re-import
   the credential when it rotates. Find the new URL in the service logs, then
   run `npm --prefix server run credential -- --url https://NEW-URL` from the
   repository root.

## Service management

### Linux

```bash
./scripts/install/linux/status.sh
./scripts/install/linux/start.sh
./scripts/install/linux/stop.sh
./scripts/install/linux/uninstall.sh
```

These wrap PM2, which remains available directly:

```bash
pm2 list
pm2 logs relay-server
pm2 restart relay-server --update-env
pm2 logs relay-tunnel
```

Linux setup requires PM2 (`npm install -g pm2`). It creates `relay-server` and,
for tunnel modes, `relay-tunnel`. Logs are under `~/.pm2/logs/` as
`relay-server-*.log` and `relay-tunnel-*.log`. `uninstall.sh` removes the PM2
processes and the Web client, offers to delete the named Cloudflare Tunnel, and
asks before removing PM2, `cloudflared` or Node.js. It leaves backend data,
tokens, and credentials in place. The
interactive terminal's PTY dependency is
compiled on Linux, so first-time setup also needs Python 3, `make`, and a C++
compiler (for example the Debian/Ubuntu `build-essential` package). Install
`zip` as well if clients will download directories.

### macOS

```bash
./scripts/install/macos/status.sh
./scripts/install/macos/start.sh
./scripts/install/macos/stop.sh
./scripts/install/macos/uninstall.sh
```

LaunchAgents are installed under `~/Library/LaunchAgents`. Logs are under
`~/Library/Logs/Relay/` as `backend.*.log` and `tunnel.*.log`. The generated
service PATH includes common Homebrew and per-user binary locations.

### Windows

For release 0.1.9, `relay-backend-windows-x64-v0.1.9.zip` includes the Node.js
runtime, npm, locked production dependencies, Web client and `Setup.exe`.
Extract the whole ZIP to a permanent writable directory and double-click
`Setup.exe`, or run `.\setup.cmd` for the console menu. Both provide install,
reinstall, uninstall, status, agent CLI installation and device token management,
using shared operations. Web defaults on. Missing `cloudflared` is downloaded
for tunnel modes. The five CLIs can be selected for installation with official
Windows installers; sign in/configure them yourself afterward.
The bundle's `README.md` explains setup and updates; `.\start.cmd`,
`.\stop.cmd`, `.\status.cmd`, `.\credential.cmd`, and `.\uninstall.cmd` wrap the
same service adapters below. The Scheduled Task starts at this user's login.

```powershell
.\scripts\install\windows\status.ps1
.\scripts\install\windows\start.ps1
.\scripts\install\windows\stop.ps1
.\scripts\install\windows\uninstall.ps1
```

Logs and PID files live under `%LOCALAPPDATA%\Relay\logs\` and
`%LOCALAPPDATA%\Relay\runtime\`. If PowerShell blocks the setup script, allow it
for the current shell only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

All three uninstall adapters remove the managed service but deliberately leave
configuration, tokens, credentials, histories, and logs for manual cleanup.

## Manual server start

For development or troubleshooting, bypass the service adapters:

```bash
cd server
npm install
cp .env.example .env
npm start
```

Authenticate the chosen agent CLI on this host, then generate a credential
separately with `npm run credential`. See
`server/.env.example` for configuration and the handbook for production
hardening.
