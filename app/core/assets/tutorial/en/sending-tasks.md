---
title: Send tasks, queue and stop
category: Chat
order: 340
summary: How replies stream, how messages queue, how to stop a turn, and replies that arrive on their own.
keywords: send, stop, cancel, queue, background, thinking, steps, streaming
---

## Writing a good task

Start broad, such as "explain the structure of this project", then ask for specific changes. Saying which files to change and what counts as done makes the result more reliable.

## Live progress

The reply appears as it is written:

- **Thinking**: the agent's reasoning, which you can expand.
- **Steps**: the tools and commands it runs, folded with a count.
- The final answer appears at the bottom.

Leaving the page, switching to another session or closing the app does not stop the task; it keeps running on the backend. Return to the session to see where it is.

## Queueing

One session runs one turn at a time. While a reply is running you can still type a follow-up; it shows as **Queued** and is sent when the current turn finishes. Different sessions and agents never wait for each other.

## Stop

While a reply runs, Send becomes **Stop**. Stop interrupts the turn but keeps the conversation, so you can carry on.

## Replies that arrive on their own

Some agents keep working in the background and reply on their own:

- **Claude Code**: when a background subagent, a timer or a background command wakes it and it writes text, a new reply appears in solo chat.
- **Codex**: replies when a child agent completes.
- **Antigravity**: replies after a timer, subagent or background command wakes it.

You can stop these with Stop too. A background turn that only runs tools stays invisible. Cursor, OpenCode, Hermes and Swarm members do not produce such replies.

## Task completion alerts

When no device is viewing the workspace, a finished task sends a notification (turn on **Task completion alerts** in Settings); see [Notifications](notifications.md).

## Errors

- **Needs login on the backend host**: sign in to that CLI on the host; see [Agent status and sign-in](agent-status.md).
- **Still handling the previous message**: try again shortly.
- A turn longer than `AGENT_TIMEOUT_MS` (60 minutes by default) is ended.
