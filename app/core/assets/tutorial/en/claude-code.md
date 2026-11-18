---
title: Claude Code
category: Agents
order: 420
summary: Sign-in, permission tiers, background work, Compress, quota and keepalive.
keywords: claude, anthropic, claude code, oauth, keepalive, compact
---

## Preparation

Install Claude Code on the backend host and sign in, then check that `claude` can hold a conversation. Relay keeps one Claude Agent SDK process **per conversation**. `RELAY_CLAUDE_BIN` picks a specific executable.

## Controls

| Control | Note |
|---|---|
| Model | main models first; older versions on the Legacy models page |
| Effort | High by default |
| Permission | Bypass (skips every check), Auto-accept edits (default; other tools may block in non-interactive mode), Plan only (read-only) |
| Fast mode | off by default |

Changing any setting restarts that conversation's process and resumes the same conversation, so the next turn is a little slower.

## Processes and idling

By default up to 3 Claude processes stay alive and close after 15 idle minutes (`RELAY_CLAUDE_MAX_LIVE`, `RELAY_CLAUDE_IDLE_MS`). A process with background tasks still running (background subagents, Monitor, background shells) is not closed as idle.

## Background replies

When background work wakes Claude and it writes text, a new reply appears in solo chat, and Stop interrupts it; see [Send tasks, queue and stop](sending-tasks.md).

## Compress

**Compress** in the composer's **+** menu sends `/compact`; see [Composer tools](composer-tools.md).

## Quota

[Quota usage](quota-usage.md) shows the five-hour and weekly quota, and the strip above the composer shows what remains. You can set a [scheduled message](scheduled-messages.md) for the next five-hour reset.

Claude's five-hour window only runs while it is used; once it lapses, the API reports no reset time. So by default the backend sends one minimal request (one output token) whenever the window is idle, to keep it cycling. It is billed like a normal request and uses a little quota; set `ENABLE_CLAUDE_KEEPALIVE=false` to turn it off. Quota checks may also refresh the host's OAuth access token.
