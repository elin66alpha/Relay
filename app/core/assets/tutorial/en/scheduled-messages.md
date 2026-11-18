---
title: Scheduled messages
category: Usage and notifications
order: 820
summary: Send a prompt automatically at the next five-hour quota reset, and Claude keepalive.
keywords: scheduled message, schedule, reset, five-hour, keepalive
---

When quota runs out, you can queue one message to send automatically at the next **five-hour window reset**, so work carries on. Claude Code and Codex only.

## Set it up

1. Open [Quota usage](quota-usage.md).
2. Select **Scheduled messages** on the Claude Code or Codex card.
3. Enter the message and save.

Each source keeps **one** message per workspace. The card shows the send time and a preview; the same dialog edits it, or **Clear scheduled** cancels it.

## Where it goes

The message goes to the workspace and session it was set from. If that session is deleted before it sends, the scheduled message fails. The turn it starts appears in the chat like any other, marked as sent after the quota reset.

## Needs the backend's quota watch

Scheduled messages need the backend's quota watch (`ENABLE_QUOTA_WATCH`, on by default). Cursor and Antigravity resets never send one.

## Claude keepalive

Claude's five-hour window only runs while it is used; once it lapses, the API reports no reset time and the app can only show unknown. To keep the window cycling, the backend by default sends one minimal Claude Code request (one output token) whenever the window is idle, then waits until just after the next reset.

It is billed like an ordinary request and uses a little quota. Set `ENABLE_CLAUDE_KEEPALIVE=false` in `server/.env` to turn it off; `CLAUDE_KEEPALIVE_MODEL` picks the model it uses.
