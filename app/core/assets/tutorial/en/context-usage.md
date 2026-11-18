---
title: Context usage
category: Chat
order: 370
summary: What "used / window" above the composer means and when it shows ?.
keywords: context, token, window, usage, 42k
---

Above the solo-chat composer, the conversation's context usage appears as `used / window` in tokens, for example `42k / 200k`.

| Shows | Means |
|---|---|
| `0 / 200k` | a new or just-cleared conversation |
| `? / 200k` | there are replies, but the agent reported no usage |
| `42k / ?` | this agent and model have not reported a window size yet |

The value is the latest usage reported in the conversation. The backend remembers the last window each agent and model reported, so an empty conversation can still show its limit.

Cursor reports no context usage, so the line is hidden while Cursor is selected. Antigravity's usage is read from its language server.

When the context is nearly full, [compress the conversation](composer-tools.md) or start a new session.
