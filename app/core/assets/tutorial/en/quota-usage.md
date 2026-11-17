---
title: Quota usage
category: Usage and notifications
order: 810
summary: Quota cards for Claude Code, Codex, Cursor and Antigravity, and the quota strip above the composer.
keywords: quota, usage, 5 hours, weekly, reset, limit
---

## Open it

**Quota usage** in the drawer.

## Cards

Each source is queried on its own, so each card fills in as soon as its source answers.

| Source | Shows |
|---|---|
| Claude Code | five-hour and weekly remaining quota and reset times; scheduled messages |
| Codex | five-hour and weekly remaining quota and reset times; scheduled messages |
| Cursor | one weekly pool on an X plan such as Premium; two pools, Cursor models and API models, on an older plan |
| Antigravity | the subscription quota for Gemini, Claude/GPT and Argon separately |

Labels on a card:

- **As of …**: when the data is from.
- **Stale**: the latest check failed and the card shows the previous result.
- **Window reset — awaiting fresh data**: the window has just reset.

Quota is separate from the login state shown in [Machine details](machine-details.md).

## The strip above the composer

In solo chat, the current agent's remaining quota shows above the composer (Claude Code, Codex, Cursor). It updates when you switch agents and after each turn, at most once a minute per agent, matching the backend's one-minute cache. Antigravity shows only a hint; check Quota usage for it.

## Notes

- Checks may read and refresh the host's OAuth access tokens, but token values never reach the app.
- Codex checks send one minimal request for rate-limit headers and can use a little quota.
- Claude keepalive is on by default; see [Scheduled messages](scheduled-messages.md).
- With no Antigravity conversation running, Relay runs `agy -p /usage` once and caches the result for five minutes.

For alerts when quota resets see [Notifications](notifications.md).
