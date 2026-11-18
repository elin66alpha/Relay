---
title: Codex
category: Agents
order: 430
summary: Sign-in modes, sandbox permissions, child-agent replies, the model catalog and quota.
keywords: codex, openai, chatgpt, app-server, sandbox, child agent
---

## Preparation

Install Codex on the backend host (`npm install -g @openai/codex`) and sign in. Relay supports Codex's modes: a ChatGPT login, an API key, an external token, and a provider configured on the host. `CODEX_HOME` sets its configuration directory.

Every Codex conversation shares one `app-server` process.

## Controls

| Control | Note |
|---|---|
| Model | from the installed CLI's catalog, keeping its order and default; older versions on the Legacy models page |
| Effort | depends on the model, Medium by default |
| Permission | Workspace write (default; network and paths outside the workspace blocked), Read only, Full access (no sandbox) |
| Fast mode | off by default |

Codex keeps approvals off on every tier, so the sandbox is the whole boundary. Model, effort and Fast mode apply per turn; changing the sandbox reopens the conversation, which stays the same conversation.

## Recheck

When you select **Recheck** in [Machine details](machine-details.md), Relay really verifies the Codex login and tries to refresh it. A missing account or a refused refresh shows as needing login; a passing probe failure shows as a check error.

## Child agents and background work

Replies from completed Codex child agents appear in solo chat. Relay turns on the experimental features this needs only for its own Codex process, without changing the host's Codex configuration.

Codex's sandbox ends each command's process group when the command returns, so a background process survives only if it detaches into its own session (`setsid`).

## Quota

[Quota usage](quota-usage.md) shows the five-hour and weekly quota, and you can set [scheduled messages](scheduled-messages.md). Checking quota sends one minimal request to read the rate-limit headers and can use a little quota. Updating Codex refreshes the model catalog.
