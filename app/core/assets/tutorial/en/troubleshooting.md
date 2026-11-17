---
title: Troubleshooting
category: Backend setup
order: 270
summary: What to check, in order, when decryption fails, the connection fails or an agent is unavailable.
keywords: troubleshooting, error, connection failed, decryption failed, logs, 401, cannot connect
---

## First: which kind of error

| Symptom | Look at |
|---|---|
| Credential decryption failed | the password or the credential file |
| Token rejected | the token was revoked, or a new credential was generated; generate and import again |
| Cannot resolve host, connection refused, network unreachable | the backend service, port, firewall, address |
| Connected but an agent is unavailable | the CLI's install and login on the host |

## Is the backend running

Run the status command in the install directory:

| OS | Command |
|---|---|
| Linux | `./scripts/install/linux/status.sh` |
| macOS | `./scripts/install/macos/status.sh` |
| Windows | `.\status.cmd` or `.\scripts\install\windows\status.ps1` |

## Logs

| OS | Where |
|---|---|
| Linux | `pm2 logs relay-server`; files in `~/.pm2/logs/` |
| macOS | `~/Library/Logs/Relay/` |
| Windows | `logs\` in the Relay folder |

## Address problems

- A Quick Tunnel address changes after a restart. Find the new one in the logs and generate a new credential; see [Network modes and HTTPS](network-modes.md).
- Other devices cannot use `localhost` to reach the backend.
- An HTTPS Web client must connect to an HTTPS backend.

## An agent is unavailable

1. Run the CLI directly in a host terminal and confirm it can hold a conversation.
2. Make sure the CLI is somewhere the backend looks (PATH, `~/.local/bin`, `~/.opencode/bin` and so on). On Windows, Setup's **Open terminal** helps check.
3. Select **Recheck** in [Machine details](machine-details.md).

Codex's Recheck really verifies its login; a network or verification error does not necessarily mean you must sign in again.

## Other cases

- **Backend too old**: the app called a route the older backend lacks; update the backend, see [Update the backend](backend-update.md).
- **Cannot change the work path**: a task is running; change it after it finishes.
- The **Status** section of Machine details lists whether the work directory exists and is writable, plus the state of each storage file; a screenshot of it helps when asking for help.
