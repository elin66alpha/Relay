---
title: Backend settings
category: Backend setup
order: 250
summary: The most useful settings in server/.env: address, default directory, timeouts, session caps, quota and push.
keywords: env, .env, configuration, environment variables, PORT, HOST, RELAY_DEFAULT_DIR, AGENT_TIMEOUT_MS, settings
---

Backend settings live in `server/.env`; `server/.env.example` documents all of them. Restart the backend after a change (Linux: `pm2 restart relay-server --update-env`).

## Identity and network

| Variable | Meaning |
|---|---|
| `PORT` | listening port, default `8787` |
| `HOST` | listening address; keep `127.0.0.1` behind a tunnel or a proxy on the same host |
| `PUBLIC_BASE_URL` | the address written into credentials; must match what clients import exactly |
| `MACHINE_ID`, `MACHINE_NAME` | machine identity and name, filled by `npm run credential` |
| `RELAY_SERVE_WEB` | `0` stops serving the Web client |
| `CORS_ALLOW_ORIGIN` | narrows cross-origin access when the Web client has a fixed origin |

## Execution

| Variable | Meaning |
|---|---|
| `RELAY_DEFAULT_DIR` | a new device's default workspace, `~/Relay` by default |
| `AGENT_TIMEOUT_MS` | longest a turn may run, 60 minutes by default |
| `PROMPT_MAX_BYTES` | largest message |
| `RELAY_TERMINAL_SHELL` | shell used by the SSH terminal |
| `TERMINAL_IDLE_TIMEOUT_MS`, `TERMINAL_BUFFER_MAX_BYTES` | how long a detached terminal is kept and how much output it keeps |
| `RELAY_BROWSER` | path of the Chrome / Chromium / Edge used by the browser |
| `CODEX_HOME` | Codex's configuration directory |

## Agent sessions

To save resources, idle sessions close and the number kept alive is capped. By default at most 3 Claude processes and 4 sessions per other agent, closed after 15 idle minutes; turns past a cap wait for a slot. A closed session resumes the same conversation on its next turn, only a little slower.

| Variable | Default |
|---|---|
| `RELAY_CLAUDE_MAX_LIVE` | 3 |
| `RELAY_CLAUDE_IDLE_MS` | 900000 |
| `RELAY_AGENT_MAX_SESSIONS` | 4 |
| `RELAY_AGENT_IDLE_MS` | 900000 |
| `RELAY_SWARM_MAX_HOPS` | 3, see [Mentions and rounds](swarm-mentions.md) |

## Files

For `RELAY_WORKSPACE_ROOT` and `RELAY_FS_ROOTS` see [File access: open or isolated](file-access-mode.md); `UPLOAD_MAX_BYTES` and `DOWNLOAD_MAX_BYTES` default to 100 MB and 300 MB.

## Quota

| Variable | Meaning |
|---|---|
| `ENABLE_QUOTA_WATCH` | watch for quota window resets, for alerts and scheduled messages |
| `QUOTA_POLL_MS` | polling interval |
| `ENABLE_CLAUDE_KEEPALIVE` | keeps Claude's five-hour window cycling, see [Scheduled messages](scheduled-messages.md) |
| `CLAUDE_KEEPALIVE_MODEL` | model used by the keepalive request |

## Offline push

`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` and `VAPID_SUBJECT` enable Web Push; `FCM_SERVICE_ACCOUNT_FILE` enables Android FCM. See [Notifications](notifications.md).
