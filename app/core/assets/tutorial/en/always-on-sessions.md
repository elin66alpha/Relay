---
title: Always-on sessions
category: Chat
order: 325
summary: Pin up to 3 solo-chat sessions per backend so their CLI processes stay warm and are never evicted.
keywords: always-on, pin, resident, keep alive, idle, eviction, memory, session
---

Normally Relay closes an idle agent session after its idle timeout and evicts the least recently used session when an agent reaches its live-session cap. Marking a solo-chat session as **always-on** exempts it from both: its CLI process stays alive while idle and is never evicted to make room for other chats.

## How to pin a session

Open a solo-chat conversation and tap the **pin icon** at the top right, next to Search:

- **Outlined pin** — ordinary session (subject to the idle timeout and live-session cap).
- **Filled pin** — always-on session. Tap it again to turn always-on off.

Pinning a session that does not have a live process yet only records the mark; the CLI starts on your next message and stays alive from then on. Turning always-on on or off never restarts a running agent process.

## Limit and capacity

Each backend allows at most **3 always-on sessions in total**, shared across all agents and workspaces. Always-on sessions do not count against an agent's ordinary live-session cap, so regular chats keep their full capacity.

If 3 sessions are already pinned, pinning a 4th is refused. Turn one off from **Home** first.

## Managing them from Home

Open **Home** from the drawer to see the **Always-on sessions** section below Recent workspaces:

- Tap any row to switch workspace, agent and session and jump straight into that conversation.
- Tap the trailing pin button to turn always-on off without leaving Home (even for a session in another workspace).

Deleting a session automatically removes its always-on mark. Swarm conversations cannot be marked always-on.

## Memory and backend restarts

- **Each always-on session keeps a CLI process running** on the backend machine, which holds memory until you turn always-on off or delete the session.
- **Always-on marks live only in backend memory.** Restarting the backend clears every always-on mark and stops the processes; nothing is re-warmed automatically on boot.

See also [Sessions](sessions.md).
