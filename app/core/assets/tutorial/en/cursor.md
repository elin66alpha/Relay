---
title: Cursor
category: Agents
order: 440
summary: The agent command and sign-in, the paid models page, one process per model choice, and usage pools.
keywords: cursor, agent, agent login, CURSOR_API_KEY, acp, paid models, composer
---

## Preparation

Cursor's CLI command is **`agent`**, not `cursor`. Run `agent login` on the backend host, or set `CURSOR_API_KEY`.

Relay drives Cursor over ACP and uses its own configuration directory, `server/cursor-config/`, so the models you choose in Relay **never** change the defaults in the host's `~/.cursor`. Sign-in still uses the host's `agent login`.

## Controls

| Control | Note |
|---|---|
| Model | Auto by default. The second page, **Models that need a payment method**, holds the models outside the plan's included usage (anything but Auto, Grok and Composer), which bill prepaid usage from the first request |
| Effort | each model has its own levels |
| Permission | Bypass (default), Plan only (read-only), Ask only (read-only) |
| Fast mode | only on models that have a fast option |

The model list refreshes at backend start, after a CLI update, and when the picker opens (at most every ten minutes). Before the first list arrives, or when Cursor is not signed in, only Auto is offered.

## One process per choice

Cursor applies the model, effort and speed to its whole process, so each combination runs in a Cursor process of its own (conversations with the same choice share one). Changing settings resumes the conversation in the matching process.

## Limits

- Cursor reports no context usage, so [Context usage](context-usage.md) is hidden while it is selected.
- It produces no background replies.
- Deleting a session makes Relay remove its directory under `server/cursor-config/acp-sessions/` itself, because Cursor has no delete command.

## Quota

[Quota usage](quota-usage.md) reads included usage from Cursor's dashboard; the check itself spends no usage. An X plan such as Premium is one weekly pool; an older plan is two pools, Cursor models and API models. Cursor resets do not trigger scheduled messages.
