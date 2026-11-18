---
title: Model, effort, permission and Fast mode
category: Chat
order: 330
summary: Each session's model, reasoning effort, permission tier and Fast mode, and how agents differ.
keywords: model, effort, reasoning, permission, fast mode, legacy models, payment
---

Tap the **+** left of the composer. The first row holds the controls the current agent supports; each opens a selection page.

## Saved per session

Settings belong to workspace + agent + session and are shared by every device on that session. A new session copies the current one's settings and is independent afterwards.

## Model

The page lists the main models first; a link at the bottom opens a second page:

- **Legacy models** (Claude Code, Codex): older versions, still selectable.
- **Models that need a payment method** (Cursor): models outside the Cursor plan's included usage (anything but Auto, Grok and Composer), which bill prepaid usage from the first request.

OpenCode lists the models OpenCode offers on the host, including providers you configured there; Hermes shows only the one model configured on the host. The CLI on the host decides which models exist; they refresh after a CLI update.

## Effort

From low to high the levels can be None, Minimal, Low, Medium, High, Extra high, Max and Ultra. Which ones appear depends on the agent and model; for Codex, Cursor and Antigravity they change with the model.

## Permission

Relay has no per-request approval screen, so the permission tier decides what an agent does when an action needs approval.

| Agent | Tiers |
|---|---|
| Claude Code | Bypass (skips every check), Auto-accept edits (default), Plan only (read-only) |
| Codex | Workspace write (default; network and other paths blocked), Read only, Full access (no sandbox) |
| Cursor | Bypass (default), Plan only (read-only), Ask only (read-only) |
| OpenCode | Bypass (default), Ask (anything needing approval is refused) |
| Hermes | Auto-approve yolo (default), Cautious (refuses anything needing approval) |
| Antigravity | Cautious (default, refuses requests needing approval), Auto-approve |

An [isolated install](file-access-mode.md) does not offer the Bypass / Full access / Auto-approve tier.

Pick by task: a read-only tier when you only want to look at code, an editing tier when you want changes.

## Fast mode

Claude Code, Codex and Cursor offer Fast mode, off by default. It trades higher usage or cost for faster responses, and depends on the model, CLI version and account. It appears only in solo chat.

## Update CLI

The last button in the row, **Update CLI**, runs that CLI's self-update on the backend host. It can take a minute or two; the model and effort lists refresh when it finishes.

## When settings take effect

- Claude Code: a change restarts its process and resumes the same conversation.
- Codex: model, effort and Fast mode apply per turn; changing the sandbox reopens the conversation.
- Cursor: each combination runs in its own process, and switching resumes the conversation in the matching one. Relay uses its own Cursor config directory, so the host's `~/.cursor` defaults never change.
- OpenCode, Hermes: apply directly, without a restart.

For each agent's details see the Agents category, starting with [Claude Code](claude-code.md).
