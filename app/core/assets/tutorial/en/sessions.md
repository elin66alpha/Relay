---
title: Sessions
category: Chat
order: 320
summary: Up to 8 named conversations per agent: create, switch, rename, delete, and share across devices.
keywords: session, conversation, main, new, rename, delete, switch
---

In one workspace, each agent can have up to **8 named sessions**. Each is a separate conversation with its own history, settings and CLI-side context.

## Where to manage them

Select an agent in the drawer and its sessions open below it:

| Action | How |
|---|---|
| Create | the **+** to the agent's right; enter a name or leave it blank |
| Switch | tap the session name |
| Rename | the edit button beside the name |
| Delete | the delete button beside the name |

A running session is marked. If the list still shows the previous workspace's sessions, use the refresh button next to the **CLI agents** heading.

## The Main session

Main keeps the original conversation and cannot be deleted or renamed.

## What deleting does

Deleting removes the session's chat history and machine-side context; **files in the workspace are not changed**. Relay also asks the CLI to delete its own transcript, but that depends on the CLI; if you need guaranteed erasure, check the CLI's data on the host.

## Shared across devices

Devices on the same workspace, agent and session share its history and live progress. Send a task from your computer and read the result on your phone.

## Settings follow the session

Model, effort, permission and Fast mode are saved per session. A new session starts from a copy of the current session's settings and is independent after that. See [Model, effort, permission and Fast mode](agent-controls.md).

## When to start a new session

Use a new session for a new task and the existing one for follow-ups. The context stays cleaner and uses less quota. Messages in one session queue one after another; different sessions run at the same time.
