# Backend setup

[中文](install.zh-CN.md) · [Deployment handbook](handbook.md#production-deployment)

Relay uses the same Node.js server and HTTP/SSE API on every backend host. The
scripts in `scripts/install/` only adapt dependency setup, process management, logs, and optional
Cloudflare Tunnel startup to each operating system. Linux and macOS share one
implementation in `scripts/install/unix/`, so both ask the same questions in the
same order; only the package manager and service manager differ.

## Requirements

- Node.js 22 or newer.
- At least one supported CLI installed on the backend: Claude Code, Codex,
  Cursor (the `agent` CLI, signed in with `agent login`), OpenCode,
  Antigravity, or Hermes.
- Every CLI must be authenticated or configured on the backend host itself.
  Relay reports status but does not perform OAuth login or collect provider
  keys.
- Unix hosts need `zip` for directory downloads. Linux setup also needs PM2,
  Python 3, `make`, and a C++ compiler for the terminal PTY dependency.
- `cloudflared` is required only for named or Quick Tunnel mode.
- On Debian and Ubuntu, Linux setup checks all of the above except the agent
  CLIs, including the Node.js version, and after one confirmation that names
  what it installs, installs what is missing with `sudo apt-get`: Node.js 24
  from NodeSource when Node.js is missing or older than 22, and `cloudflared`
  from Cloudflare's release `.deb` when a tunnel mode needs it. Other
  distributions get the name of what to install. Run it as the user who will
  run Relay, not with `sudo`.
- On macOS, setup does the same with Homebrew after one confirmation: the
  current Node.js when it is missing or older than 22, `zip`, and `cloudflared`
  for a tunnel mode. Without Homebrew it names what to install. The terminal's
  PTY module ships prebuilt for macOS; only if that binary does not load does
  setup open the Xcode Command Line Tools installer to compile it.
- Before upgrading an existing Relay installation to 0.1.10 or later, update
  Node.js to 22 or newer. The updater checks this before replacing
  files and leaves the existing installation untouched if it is too old.

## Install

Linux and macOS share `relay-backend-linux-macos-v<VERSION>.tar.gz`. Download it from [GitHub Releases](https://github.com/elin66alpha/Relay/releases/latest) and compare its SHA-256 digest with its entry in `SHA256SUMS`. Extract it to a permanent writable directory and run `./install.sh` from the folder containing `server/`.

To upgrade in place, run `./scripts/install/unix/update.sh` from the installation directory or use **Update and restart** in Machine details. The updater checks the archive against the release’s `SHA256SUMS` and keeps your configuration, tokens and chats. It exits without changes when the installation already has the latest release (`RELAY_VERSION=<version>` installs a given one anyway). It unpacks the release and runs `npm ci --omit=dev` in `.relay-update-new/` first, so a failed download or dependency install changes nothing; then it moves the previous version to `.relay-update-old/`, restarts only the backend through the new release's service adapter, and puts the previous version back when the backend does not answer on its port within 30 seconds. A run interrupted mid-way is undone by the next one.

If setup reports that Relay is installed from another folder (a newer release extracted beside the old one), upgrade that installation with the `RELAY_DIR=... update.sh` command it prints. Reinstalling in the new folder moves the service there with a fresh `server/.env` and no tokens or chats.

For an installation from 0.1.12 or earlier, extract the new archive to a separate directory. From that new folder run `RELAY_DIR="/absolute/path/to/existing/relay" ./scripts/install/unix/update.sh`, substituting the existing installation path.

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

On Linux and macOS, `setup.sh` opens the same menu: install, reinstall (keeps tokens, chats and
settings), uninstall, service status (address, tunnel hostnames, Web client,
agent install and sign-in state, tokens), install agent CLIs, and create,
delete, list or re-show a device token. Installing agent CLIs lists Claude Code,
Codex, Cursor, OpenCode, Antigravity and Hermes with the install state the
backend itself reports (`server/scripts/setup-status.js`), installs the ones you
pick with each CLI's official installer (`npm install -g @openai/codex` for
Codex), and prints their login commands; Relay never signs a CLI in. Install
runs the same step. Re-showing reuses the token and asks for a new QR password, since
the old one is not stored; with a Quick Tunnel it uses the tunnel's current
address from its log. Install and reinstall ask whether to serve the Web
client at the backend address (default yes), and then for file access:

- **Open** (the default): agents and the file browser reach every file the
  backend user can.
- **Isolated**: work directories, the file browser and SSH's starting directory
  stay inside `workspace/` in the installation directory, and agents lose their full-auto / unsandboxed
  permission tier. Setup writes the directory to `RELAY_WORKSPACE_ROOT` in
  `server/.env`. This is Relay's own path policy, not an operating-system
  sandbox: agent CLIs and the terminal still run as the backend user.

Rerunning install or reinstall offers the current choice as the default; the
service status shows it as `File access`. Uninstall keeps `workspace/` and its
files.

The source setup package (`relay-backend-linux-macos-v<VERSION>.tar.gz`) includes
the compiled Web client, in `app/shell/build/web`; the backend serves it at `/`
unless `server/.env` sets `RELAY_SERVE_WEB=0`. The API under `/api` always requires a
device token. The Windows backend ZIP includes the same compiled Web client:

- Linux, macOS and Windows setup ask whether to serve it; uninstall removes it
  while retaining backend state. Windows serves Web and API in one Node.js process,
  without a separate Web server.
- A source checkout has it only after `flutter build web`.

### Network modes

1. **Direct:** use your own reachable address. The server binds to `0.0.0.0`;
   put HTTPS in front before exposing it publicly.
2. **Named Cloudflare Tunnel:** use a stable hostname in a Cloudflare zone. The
   server stays on `127.0.0.1`.
3. **Cloudflare Quick Tunnel:** useful for a trial. The generated
   `trycloudflare.com` URL changes whenever the tunnel restarts, and setup says
   so when it finishes. Show a token's QR again from the setup menu (choice 9),
   which reads the current URL from the tunnel log on every OS, and re-import
   it on each device.
4. **Tailscale.** The default when this machine is on a tailnet. Relay listens only on the detected tailnet IPv4. Native apps can use `http://<tailscale-ip>:<port>` over WireGuard. Relay Web needs HTTPS to store credentials. To use it, configure a reverse proxy with a trusted certificate on port 443 forwarding to that tailnet IP and backend port, then enter its hostname during setup. Open that HTTPS address and import the generated credential. Leaving the hostname blank configures native apps only and disables Web. If Tailscale is unavailable, setup returns to the network menu.

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
for tunnel modes, `relay-tunnel`, and offers to register PM2's systemd service
(`pm2 startup systemd`, with `sudo` once) so both come back after a reboot; on a
host without systemd, run `start.sh` after each boot. Logs are under `~/.pm2/logs/` as
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

These are the Linux scripts with launchd in place of PM2: the backend and,
for tunnel modes, the tunnel run as the LaunchAgents `dev.relay.app.backend`
and `dev.relay.app.tunnel` under `~/Library/LaunchAgents`, start at login (so
after a restart Relay waits for a login), and restart when they exit. Logs are
under `~/Library/Logs/Relay/` as `backend.*.log` and `tunnel.*.log`. The backend
LaunchAgent runs the `node` setup found by its full path, with that node's
folder first on the generated service PATH, so a Node.js from nvm, fnm or Volta
works; the PATH also includes common Homebrew and per-user binary locations. `uninstall.sh` removes the LaunchAgents
and the Web client, offers to delete the named Cloudflare Tunnel, and asks
before removing a Homebrew `cloudflared` or Node.js. It leaves backend data,
tokens, and credentials in place.

### Windows

`relay-backend-windows-x64-v<VERSION>.zip` from each release includes the Node.js
runtime, npm, locked production dependencies and the Web client. Extract the
whole ZIP to a permanent writable directory and run `.\setup.cmd` there. Setup
is command-line only, like Linux and macOS: the same menu (install, reinstall,
uninstall, status, agent CLI installation and device token management) and the
same six install steps, including the open/isolated file access choice.
Web defaults on. Missing `cloudflared` is downloaded
for tunnel modes. The six CLIs can be selected for installation with official
Windows installers; sign in/configure them yourself afterward. Setup appends
the folders holding an agent CLI (such as `%APPDATA%\npm`) to your user PATH,
plus the bundled Node when the host has none, so new terminals find them;
menu choice `t` opens one right away. Uninstall removes only the entries setup
added.
The bundle's `README.md` explains setup and updates; `.\start.cmd`,
`.\stop.cmd`, `.\status.cmd`, `.\credential.cmd`, and `.\uninstall.cmd` wrap the
same service adapters below, and `.\update.cmd` upgrades the installation in
place to the latest release. The Scheduled Task starts at this user's login, so
after a restart Relay waits for a sign-in. The backend runs through
`server/scripts/keep-running.js`, which starts it again five seconds after it
exits, as PM2 and launchd do. Like Linux and macOS, setup defaults the network
mode to Tailscale on a tailnet, warns that a Quick Tunnel's URL changes, and
says when Relay is already installed from another folder.

```powershell
.\scripts\install\windows\status.ps1
.\scripts\install\windows\start.ps1
.\scripts\install\windows\stop.ps1
.\scripts\install\windows\uninstall.ps1
```

Logs live in `logs\` inside the Relay directory (backend and tunnel
`.out`/`.err` logs; a restart appends to them); PID files live under
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
