# Windows Backend

The Windows backend reuses the shared Node server in `server/` and manages the
backend processes with PowerShell plus a per-user Scheduled Task that starts
Relay at login.

## Requirements

- Windows 10/11 with Node.js 18 or newer.
- Claude Code / Codex / Antigravity CLIs installed and logged in on Windows.
- `cloudflared` for Cloudflare Tunnel or Quick Tunnel mode.
- PowerShell. Windows PowerShell 5.1 is enough; PowerShell 7 also works.

Install Node.js from <https://nodejs.org/> and install `cloudflared` from
Cloudflare's Windows package or by placing `cloudflared.exe` on `PATH`.

## Setup

Run PowerShell from the repository root:

```powershell
.\backends\windows\setup.ps1
```

If script execution is blocked on the machine, run this command for the current
session and retry:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

The setup script:

- creates `server\.env` from `server\.env.example` when needed;
- installs backend npm dependencies;
- offers direct mode, named Cloudflare Tunnel mode, or Quick Tunnel mode;
- starts the backend and optional tunnel as background processes;
- registers a per-user Scheduled Task named `Relay Backend` so the backend
  starts again after login;
- for Quick Tunnel, reads the latest `trycloudflare.com` URL from the tunnel
  logs;
- runs `npm run credential` so the terminal shows and saves the encrypted
  credential QR pointing at the chosen public URL.

## Service Commands

```powershell
.\backends\windows\status.ps1
.\backends\windows\start.ps1
.\backends\windows\stop.ps1
.\backends\windows\uninstall.ps1
```

Logs and PID files live under:

```text
%LOCALAPPDATA%\Relay\logs\
%LOCALAPPDATA%\Relay\runtime\
```

## Notes

The Windows scripts do not require PM2. They keep platform-specific process
management in `backends/windows/` while the HTTP API, credentials, sessions, and
agent dispatch stay shared in `server/`.

In Cloudflare Tunnel and Quick Tunnel modes the backend binds to `127.0.0.1`,
and cloudflared reaches it locally. For direct mode (public IP/domain), bind to
`0.0.0.0` and put a reverse proxy with HTTPS in front of it before exposing it
beyond a trusted network.
