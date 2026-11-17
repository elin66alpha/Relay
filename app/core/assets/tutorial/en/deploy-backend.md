---
title: Deploy the backend
category: Getting started
order: 120
summary: Prepare the host, run setup, choose a network mode and get a credential, all on one page.
keywords: install, deploy, setup, backend, Node.js, QR, credential
---

Relay's agents run on a computer or server you own; the app is just the door to them. This page walks through the whole deployment in order. For per-OS detail see [Install on Linux and macOS](install-linux-macos.md) and [Install on Windows](install-windows.md).

## 1. Prepare a backend machine

A home PC, a Mac or a cloud server all work. You need:

- **Node.js 22 or newer**.
- **At least one CLI agent**: Claude Code, Codex, Cursor (its command is `agent`), OpenCode, Antigravity (`agy`) or Hermes.
- To **sign in to or configure each CLI yourself on the host**. Relay only reads the login state and never signs in for you.

First confirm in a host terminal that the chosen CLI can hold a conversation. Linux also needs PM2, Python 3, `make` and a C++ compiler (the terminal is compiled); folder downloads on Linux and macOS need `zip`; a Cloudflare tunnel needs `cloudflared`. When any of these is missing, setup installs it after you confirm (`sudo apt-get` on Debian/Ubuntu, Homebrew on macOS).

## 2. Download and run setup

Linux and macOS share one backend archive. Download `relay-backend-linux-macos-v<VERSION>.tar.gz` from [GitHub Releases](https://github.com/elin66alpha/Relay/releases/latest), extract it to a permanent writable directory, and run `./install.sh` from the extracted folder containing `server/`.

On Windows, download `relay-backend-windows-x64-v<VERSION>.zip` from [GitHub Releases](https://github.com/elin66alpha/Relay/releases/latest), **extract the whole ZIP** to a permanent folder and run `.\setup.cmd` there: the same command-line menu as on Linux and macOS. The ZIP includes Node.js, dependencies and the Web client.

From a copy of the repository, run the script for your OS from its root:

| OS | Command |
|---|---|
| Linux | `./scripts/install/linux/setup.sh` |
| macOS | `./scripts/install/macos/setup.sh` |
| Windows PowerShell | `.\scripts\install\windows\setup.ps1` |

Setup asks for the port, whether to serve the Web client, the file access mode (see [File access: open or isolated](file-access-mode.md)), and can install missing CLI agents; afterwards run the login command it prints in a host terminal.

## 3. Choose how the app reaches the backend

| Mode | Good for | Note |
|---|---|---|
| Direct | LAN, Tailscale, or your own HTTPS reverse proxy | enter an address the client device can actually reach; other devices cannot use `localhost` to reach your host. Add HTTPS before exposing it to the internet |
| Named Cloudflare Tunnel | long-term use | needs your own domain on Cloudflare; a stable HTTPS address |
| Cloudflare Quick Tunnel | a trial | no domain needed, but the `trycloudflare.com` address may change after a restart, and then you must generate and import a new credential |

See [Network modes and HTTPS](network-modes.md).

## 4. Get the encrypted credential

Once setup starts the backend, it prints an encrypted credential QR code in the terminal and writes `.relay.png` and `.relay.json` under `server/credentials/`. You choose a password while generating it; it is not stored anywhere, so keep it.

**Generate a separate credential for each device**, so you can revoke one device on its own later.

## 5. Connect in the app

Go to the app's credential page (**Manage credentials** at the top of Settings): phones can scan the QR; every platform can upload the QR image or paste the JSON, then enter the password. See [Import a credential and manage machines](import-credential.md).

Once connected:

1. Tap the machine on Home to open [Machine details](machine-details.md) and check that the CLI shows ready.
2. Open **File system**, go to your project and select **Set as work path**.
3. Pick an available agent and send a simple task; see [Your first task](first-task.md).

## It does not connect?

First tell a **decryption error** (check the password and credential file) from a **connection error** (check the backend service, port, firewall and address). The full checklist is in [Troubleshooting](troubleshooting.md).

For a long-term, hardened deployment (auto-start, HTTPS, reverse proxy, restricted directories) see `docs/handbook.md` in the repository.
