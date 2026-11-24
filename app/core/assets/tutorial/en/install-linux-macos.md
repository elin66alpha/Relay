---
title: Install on Linux and macOS
category: Backend setup
order: 210
summary: Install from the archive and upgrade in place, every setup menu item, service management and log locations.
keywords: linux, macos, ubuntu, debian, install.sh, pm2, launchd, homebrew, upgrade, logs
---

Linux and macOS share one set of scripts (`scripts/install/unix/`), so the menu and setup steps are identical; only the package manager and service manager differ.

| | Linux | macOS |
|---|---|---|
| Installs system software with | `sudo apt-get` (Debian/Ubuntu) | Homebrew |
| Runs the service with | PM2 (`relay-server`, `relay-tunnel`), started at boot by PM2's systemd service | LaunchAgents (`dev.relay.app.backend`, `dev.relay.app.tunnel`), started at login |
| Logs | `~/.pm2/logs/relay-server-*.log` | `~/Library/Logs/Relay/backend.*.log` |

## Install from the backend archive

Download `relay-backend-linux-macos-v<VERSION>.tar.gz` from [GitHub Releases](https://github.com/elin66alpha/Relay/releases/latest), extract it to a permanent writable directory, and run `./install.sh` from the extracted folder containing `server/`.

Run it as the ordinary user that will run Relay, **not with sudo**.

## Requirements

- Node.js 22+. When it is missing or too old, Linux installs Node.js 24 from NodeSource and macOS installs the current one with Homebrew.
- Linux needs PM2, Python 3, `make` and a C++ compiler (`build-essential` on Debian/Ubuntu).
- Folder downloads need `zip`.
- Tunnel modes need `cloudflared`, which setup installs when needed.
- On macOS the terminal module ships prebuilt; only if it does not load does setup open the Xcode Command Line Tools installer to compile it.

Setup names what it is about to install before asking for `sudo` or Homebrew. On Linux, install also offers to start Relay when the machine boots (`pm2 startup`, which needs `sudo` once); without systemd, run `start.sh` after each boot. On macOS the LaunchAgents start when you log in, so after a restart Relay waits for a login. A Node.js from nvm, fnm or Volta works: the LaunchAgent runs that same `node` by its full path.

## The setup menu

`setup.sh` opens a menu:

| Item | Does |
|---|---|
| Install / Reinstall | reinstall keeps tokens, chats and settings |
| Uninstall | removes the services and the Web client; keeps data, tokens and credentials; asks before deleting the named tunnel and PM2, `cloudflared` or Node.js |
| Service status | address, tunnel hostnames, Web client, each CLI's install and sign-in state, tokens, file access mode |
| Install agent CLIs | lists Claude Code, Codex, Cursor, OpenCode, Antigravity and Hermes with the install state the backend sees, installs the ones you pick with their official installers, and prints their login commands |
| Device tokens | create, delete or list tokens, or show a QR again |

Install asks, in order: which agent CLIs to install, whether to serve the Web client at the backend address (default yes), the file access mode (see [File access: open or isolated](file-access-mode.md)), the port (default 8787), the network mode (see [Network modes and HTTPS](network-modes.md)), and the credential password. The network mode defaults to Tailscale when this machine is on a tailnet, otherwise to Quick Tunnel.

A Quick Tunnel's `trycloudflare.com` address changes whenever the tunnel restarts. Setup says so at the end; afterwards choose **9** in the menu to show a token's QR again with the current address, and scan it on each device.

If the menu says Relay is installed from another folder (for example a newer release extracted beside the old one), upgrade that installation with the `update.sh` command it prints. Reinstalling in the new folder starts over without the old tokens and chats.

## Service management

From the install directory:

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

To upgrade in place, run `./scripts/install/unix/update.sh` from the installation directory or use **Update and restart** in Machine details. The updater checks the archive against the release’s `SHA256SUMS` and keeps your configuration, tokens and chats. It does nothing when you already have the latest release, and puts the previous version back when the new one does not start. See [Update the backend](backend-update.md).
