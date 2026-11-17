---
title: Install on Linux and macOS
category: Backend setup
order: 210
summary: The one-line install and upgrade, every setup menu item, service management and log locations.
keywords: linux, macos, ubuntu, debian, install.sh, pm2, launchd, homebrew, upgrade, logs
---

Linux and macOS share one set of scripts (`scripts/install/unix/`), so the menu and setup steps are identical; only the package manager and service manager differ.

| | Linux | macOS |
|---|---|---|
| Installs system software with | `sudo apt-get` (Debian/Ubuntu) | Homebrew |
| Runs the service with | PM2 (`relay-server`, `relay-tunnel`) | LaunchAgents (`dev.relay.app.backend`, `dev.relay.app.tunnel`), started at login |
| Logs | `~/.pm2/logs/relay-server-*.log` | `~/Library/Logs/Relay/backend.*.log` |

## One-line install or upgrade

```bash
curl -fsSL https://github.com/elin66alpha/Relay/releases/latest/download/install.sh | bash
```

It downloads the latest release, verifies it against `SHA256SUMS`, unpacks it into `~/relay` (change it at the prompt, or set `RELAY_DIR`) and runs setup. Running it again **upgrades in place**: `server/.env`, tokens, chats and settings are kept and the backend restarts. `RELAY_VERSION=<VERSION>` installs a specific release.

Run it as the ordinary user that will run Relay, **not with sudo**.

## Requirements

- Node.js 22+. When it is missing or too old, Linux installs Node.js 24 from NodeSource and macOS installs the current one with Homebrew.
- Linux needs PM2, Python 3, `make` and a C++ compiler (`build-essential` on Debian/Ubuntu).
- Folder downloads need `zip`.
- Tunnel modes need `cloudflared`, which setup installs when needed.
- On macOS, if the terminal module must be compiled, setup opens the Xcode Command Line Tools installer.

## The setup menu

`setup.sh` opens a menu:

| Item | Does |
|---|---|
| Install / Reinstall | reinstall keeps tokens, chats and settings |
| Uninstall | removes the services and the Web client; keeps data, tokens and credentials; asks before deleting the named tunnel and PM2, `cloudflared` or Node.js |
| Service status | address, tunnel hostnames, Web client, each CLI's install and sign-in state, tokens, file access mode |
| Install agent CLIs | lists Claude Code, Codex, Cursor, OpenCode and Hermes with their install state, installs the ones you pick with their official installers, and prints their login commands |
| Device tokens | create, delete or list tokens, or show a QR again |

Install asks, in order: the port, the network mode (see [Network modes and HTTPS](network-modes.md)), whether to serve the Web client at the backend address (default yes), the file access mode (see [File access: open or isolated](file-access-mode.md)), and the credential password.

## Service management

From the install directory (`~/relay` by default):

```bash
./scripts/install/linux/status.sh
./scripts/install/linux/start.sh
./scripts/install/linux/stop.sh
./scripts/install/linux/uninstall.sh
```

On macOS replace `linux` with `macos`. On Linux PM2 also works directly:

```bash
pm2 list
pm2 logs relay-server
pm2 restart relay-server --update-env
```

## Upgrading

Three ways do the same thing: run the one-line command again; choose Reinstall in the setup menu; or select **Update to x and restart** in the app's Machine details, see [Update the backend](backend-update.md).
