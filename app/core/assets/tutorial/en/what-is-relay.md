---
title: What Relay is
category: Getting started
order: 110
summary: What Relay is made of, where your data goes, and what it does and does not do.
keywords: introduction, architecture, backend, client, privacy, overview
---

Relay turns the CLI agents **on your own machine** (Claude Code, Codex, Cursor, OpenCode, Antigravity, Hermes) into a chat workspace you can open from a phone, the Web, or a desktop.

## Two parts

| Part | Runs on | Does |
|---|---|---|
| Relay backend | your computer or server (Node.js 22+) | starts and keeps each CLI's sessions; manages files, the terminal, the browser and quota |
| Relay client | phones (Android, iOS), Web, desktops (Windows, macOS, Linux) | the chat interface; everything goes through the backend |

The client talks to the backend over HTTP and SSE with a token. There is no Relay cloud account and no relay server in between: source code, shell access and CLI logins stay on the backend machine.

## Key ideas

- **Machine**: one backend. The client can hold credentials for several machines and switch between them; see [Import a credential and manage machines](import-credential.md).
- **Workspace (work path)**: a directory on the backend where agents work. Each device remembers its own workspace on each machine; see [Workspaces](workspaces.md).
- **Session**: up to 8 named conversations per agent in a workspace; see [Sessions](sessions.md).
- **Swarm**: several agents working together in one transcript; see [Create a Swarm](swarm-basics.md).

A conversation is identified by workspace + agent + session. Different conversations run at the same time without affecting each other; messages sent to the same conversation queue and run one after another.

## Relay is not a sandbox

Agents and the terminal have every permission of the backend OS user. Relay limits only the paths the file browser can see, not the agents themselves. Run the backend as an ordinary, restricted user; see [Security](security.md).

## Next

1. [Deploy the backend](deploy-backend.md)
2. [Import a credential and manage machines](import-credential.md)
3. [Your first task](first-task.md)
