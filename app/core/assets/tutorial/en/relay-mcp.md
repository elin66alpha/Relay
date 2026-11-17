---
title: Relay MCP
category: Advanced
order: 1010
summary: Let your own agent (an MCP client) use a Relay backend the way the app does.
keywords: mcp, bot, personal agent, stdio, RELAY_CREDENTIAL, automation
---

`mcp/` is a stdio [MCP](https://modelcontextprotocol.io) server that lets a personal agent, such as a chat bot, use a Relay backend the way the app does. It has no npm dependencies; the machine running the MCP client needs Node.js 22+ and need not be the backend host.

It signs in exactly like the app, with a credential JSON and its password, and talks only to the backend's HTTP API.

## Setup

**1. Generate a separate credential for the bot**, so it can be revoked on its own. From `server/` on the backend:

```bash
npm run credential -- --label grokbot
```

The credential's address must be fixed: a named tunnel or other domain, or a LAN / Tailscale address the bot can reach. **A Cloudflare Quick Tunnel (`*.trycloudflare.com`) is refused**, because it changes on every restart.

**2. Get the code on the bot's machine**:

```bash
git clone --depth 1 https://github.com/elin66alpha/Relay.git
```

**3. Add a stdio MCP server to the bot**:

| Field | Value |
|---|---|
| command | `node` |
| args | `["<clone>/mcp/index.js"]` |
| env `RELAY_CREDENTIAL` | the credential JSON text, or a path to the `.relay.json` file |
| env `RELAY_CREDENTIAL_PASSPHRASE` | the credential password |
| env `RELAY_WORKDIR` (optional) | the starting workspace; the backend's by default |
| env `RELAY_MCP_NAME` (optional) | the name shown in Machine details, `Relay MCP (<name>)` |

Keep the password in the bot's secret store, not in chat or in a file next to the credential.

## What it can do

Status and the agent list; model, effort, permission and other settings; send a message, poll a task, cancel; history, search and export; sessions; the workspace; browse and read or write text files; Swarms (not members on other machines); quota and scheduled messages; machine hardware and diagnostics; type into this credential's own terminal and read the output.

It cannot: set wallpaper, register for push, switch machines (add one MCP server per backend), manage tokens, or open the app's local settings screens.

## Behaviour to know

- Sending waits up to `waitSeconds` (20 by default), then returns `running` with a `requestId`; the backend keeps going, so poll the task tool until it is done.
- The workspace belongs to the MCP process, so switching it moves no other device; but **conversations are shared**: the app sees the bot's messages in the same workspace, agent and session.
- The credential grants what the app grants: every agent, files outside the denylist, and a shell. Revoke its token in [Machine details](machine-details.md) to cut it off.
- If the bot is itself a coding agent, do not point it at the directory it is working in, or two agents will edit the same files.
