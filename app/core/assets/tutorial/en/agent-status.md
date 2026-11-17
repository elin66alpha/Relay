---
title: Agent status and sign-in
category: Agents
order: 410
summary: What the status lights mean, why Relay never signs in for you, and Recheck and Update CLI.
keywords: status, login, sign in, authentication, not installed, not logged in, recheck, status lights, update CLI
---

## Every sign-in happens on the host

Relay never signs a CLI in remotely and never collects provider keys. Each CLI is signed in or configured **on the backend host** in its own way. Relay only reads the login state and sends a normalized status to the app; account identity and credential values never leave the backend.

| Agent | Host preparation |
|---|---|
| Claude Code | sign in with `claude` |
| Codex | `codex login`, or an API key or other mode |
| Cursor | `agent login`, or set `CURSOR_API_KEY` |
| Antigravity | `agy acp --login` |
| OpenCode | configure a provider in OpenCode on the host |
| Hermes | configure the model and key in Hermes on the host |

## Status lights

Each agent in the drawer has one or two small lights on its right:

- The first: installed or not.
- The second (agents that need a login, such as Claude Code, Codex, Cursor and Antigravity): login ready or not.

Unusable agents fold into the drawer's last row, "n unavailable"; tapping one tells you why, for example "not installed on the backend host" or "needs login on the backend host".

## CLI agents in Machine details

[Machine details](machine-details.md) lists each agent's installed, authenticated and usable state. After signing in on the host, select **Recheck**.

- Codex's Recheck really verifies the current login with its app-server; a network or verification failure shows as a check error and does not necessarily mean you must sign in again.
- Every CLI renews its own login, so Relay shows no login-expiry countdown.

## Where CLIs are found

The backend looks on PATH, then in common per-user install locations (such as `~/.local/bin` and `~/.opencode/bin`), and caches the result for a minute. If an installed CLI shows as not installed, make sure the user running the backend can find it. Windows Setup adds the CLIs' folders to the user PATH.

## Update CLI

**Update CLI** in the composer's **+** menu runs that CLI's self-update on the host (a minute or two) and refreshes its model list. The setup menu's **Install agent CLIs** installs missing ones.
