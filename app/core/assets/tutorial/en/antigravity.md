---
title: Antigravity
category: Agents
order: 450
summary: Installing and signing in agy, isolated sessions, model and effort, permissions and quota pools.
keywords: antigravity, agy, gemini, google, argon, acp, quota
---

## Preparation

1. Install a recent `agy` on the backend host that supports `agy acp --process-per-session`.
2. Run `agy acp --login`.
3. Restart the Relay backend and recheck the status in [Machine details](machine-details.md).

Windows Setup can install Antigravity too.

## Sessions

Each conversation has its own session worker, so several conversations run at once, each with independent model and settings. Replies stream and reuse the live session; after a session is evicted, the saved conversation resumes automatically.

## Controls

| Control | Note |
|---|---|
| Model | from `agy models`, refreshed at backend start and when the picker opens (at most every ten minutes) |
| Effort | a model's effort variants are merged into one model with a separate effort control, ordered low to high |
| Permission | Cautious (default, refuses requests that need approval), Auto-approve |

## Background replies

When a timer, subagent or background command wakes Antigravity and it writes a reply, it appears in solo chat, and Stop interrupts it.

## Context

Context usage is read from Antigravity's language server; see [Context usage](context-usage.md).

## Quota

[Quota usage](quota-usage.md) shows the subscription quota, with Gemini, Claude/GPT and Argon each shown separately; the strip above the composer shows only a short hint pointing there.

With an Antigravity conversation running, quota answers at once; otherwise Relay runs `agy -p /usage` once (about two seconds, no model turn). Results are cached for five minutes. Antigravity does not support scheduled messages.

## Deleting and security

Deleting a session in Relay closes its live session and forgets its ID; `agy`'s own transcripts stay managed by the CLI on the host. Antigravity's login files cannot be read through the file browser.
