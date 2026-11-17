---
title: Security
category: Advanced
order: 1020
summary: What Relay protects, what it does not, and the checklist before a public deployment.
keywords: security, https, token, sandbox, permissions, hardening, production
---

## What Relay protects

- Every HTTP API request needs a revocable token; failed attempts are rate-limited.
- Credentials are encrypted with PBKDF2-HMAC-SHA256 and AES-256-GCM.
- The terminal and browser connect with single-use tickets valid for 30 seconds, so the long-lived token never appears in a WebSocket address.
- The file API denies Relay's, SSH's, Claude's, Codex's, Cursor's and Antigravity's sensitive files, and `RELAY_FS_ROOTS` narrows it further; see [File access: open or isolated](file-access-mode.md).
- Quota checks may read and refresh OAuth files on the host, but token values never reach the API or the app.
- Another machine's credential is sent by the app per request and never stored by the backend; see [Members on other machines](swarm-remote-members.md).

## Relay is not a sandbox

Agents and the terminal have every permission of the backend OS user. Path policy applies only to the file browser, not to the commands agents run.

## Before a public deployment

- Terminate TLS at a named tunnel or a reverse proxy (Caddy, Nginx and so on).
- Keep `HOST=127.0.0.1` behind a tunnel or a proxy on the same host; expose direct mode only behind HTTPS and a firewall.
- Set `PUBLIC_BASE_URL` to the exact address clients import, and regenerate credentials when it changes.
- Run Relay as a restricted non-root user and limit the files it can reach.
- Set `RELAY_FS_ROOTS`.
- One credential per device; revoke, then delete, unused devices; see [Device tokens](device-tokens.md).
- Use the Web client only on trusted devices, ideally in a dedicated browser profile.

For the full picture see `docs/SECURITY.md` and `docs/handbook.md` in the repository.
