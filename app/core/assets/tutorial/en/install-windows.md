---
title: Install on Windows
category: Backend setup
order: 220
summary: Install with setup.cmd, put the CLIs on PATH, manage the service, find logs and upgrade in place.
keywords: windows, setup.cmd, powershell, scheduled task, update.cmd, install
---

## Install

1. Download `relay-backend-windows-x64-v<VERSION>.zip` from [GitHub Releases](https://github.com/elin66alpha/Relay/releases/latest). Not `relay-client-windows-x64-v<VERSION>.zip`: that one is the desktop client.
2. **Extract the whole ZIP** to a permanent, writable folder (do not move it later).
3. Open PowerShell in that folder, run `.\setup.cmd` and choose `1) Install`. Setup is a command-line menu, the same as on Linux and macOS (double-clicking `setup.cmd` opens it too).

The ZIP includes the Node.js runtime, npm, production dependencies and the Web client; one Node.js process serves both the Web client and the API.

## What setup does

- Install, reinstall, uninstall, show status, and manage device tokens.
- Choose whether to serve the Web client (on by default), the network mode and the [file access mode](file-access-mode.md). A missing `cloudflared` is downloaded for tunnel modes.
- Install any of Claude Code, Codex, Cursor, OpenCode and Hermes, and Antigravity, with their official Windows installers. Sign in or configure them yourself afterwards.
- Append the folders that hold an agent CLI (such as `%APPDATA%\npm`, where Codex and OpenCode install) to your **user PATH**, plus the bundled Node when the host has none (npm's command shims need it). Uninstall removes only the entries it added.
- Menu choice `t` opens a PowerShell with the backend's PATH and lists each CLI's sign-in command.

The backend runs as a per-user **Scheduled Task** that starts when you sign in to Windows.

## Common commands

In the Relay folder:

| Command | Does |
|---|---|
| `.\start.cmd` / `.\stop.cmd` | start / stop |
| `.\status.cmd` | show status |
| `.\credential.cmd` | generate a credential |
| `.\update.cmd` | upgrade to the latest release (checked against `SHA256SUMS`); the tunnel keeps running |
| `.\update.cmd -Archive <zip>` | upgrade from a ZIP downloaded by hand |
| `.\uninstall.cmd` | remove the service, keeping configuration, tokens, credentials, history and logs |

From a source checkout the scripts are `.\scripts\install\windows\setup.ps1`, `status.ps1`, `start.ps1`, `stop.ps1` and `uninstall.ps1`. If PowerShell blocks a script, allow it for the current window only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Logs

`logs\` in the Relay folder: the backend and tunnel `.out` / `.err` logs. Setup prints its progress in the console window. PID files live in `%LOCALAPPDATA%\Relay\runtime\`.

## Drives

A Windows backend reports every drive letter, and the file browser's first path segment switches between `C:\`, `D:\` and so on; see [Browse files and switch disks](file-browser.md).
