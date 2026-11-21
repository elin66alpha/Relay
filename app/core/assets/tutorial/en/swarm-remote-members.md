---
title: Members on other machines
category: Swarms
order: 530
summary: Add agents from another Relay backend to a Swarm: requirements, behaviour and errors.
keywords: remote, other machine, peer, multi-machine, swarm member, PEER_UNREACHABLE
---

A Swarm member can be an agent on **another Relay backend**. The Swarm, its transcript and its rounds stay on the backend that hosts it (A); when a remote member's turn comes, A sends it through the other backend's (B's) ordinary API. B needs no change and may run an older version.

## Requirements

- This device holds B's credential under Settings → Machine credentials.
- The app sends B's credential with each request; A **never stores** it.

## Adding one

In the Swarm form, other machines' agents are listed after this machine's, labelled with the machine's name, for example `Claude Code (Studio)`. When two members share an agent label, the local one also appends this machine's hostname. You can summon a remote member with a readable handle like `@studio:claude` as well as `@<peerId>:claude` (or its nickname).

Adding one checks that B is reachable and has that agent, then creates a dedicated hidden swarm session on B (`Swarm: <swarm name>`). Hidden swarm sessions do not appear in B's drawer, never become B's active session, do not count toward B's 8-session limit, and are excluded from history search. Against older versions of B, A restores B's previous active session once concurrent turns finish.

A remote member sets only its **nickname, prompt and work directory on B** (defaulting to B's default directory). You can change it later from **Change work directory**, which creates a new session in the new directory and deletes the old one. Model, effort and permission follow that session's settings on B. Each member's prompt tells it where every member runs and that it cannot directly read files on another machine.

## Without B's credential

On a device without B's credential, the member shows "This device is not connected to that machine". Summoning it fails its turn while the other members run. So only a device that holds B's credential can summon B's members.

## Errors

| Case | Result |
|---|---|
| B unreachable, credential refused, timeout | that member's turn ends with an error |
| B lacks the agent when adding | adding fails and nothing is created |

## Stop, delete and clear

- Stop cancels the turn on B with the same request id.
- Deleting the Swarm or removing the member deletes its session on B, and clearing the Swarm clears it (when the request carries B's credential); none of these blocks the change on A.

B sees these as ordinary turns from this device. The round's one notification comes from A; B sends none for its swarm sessions (versions of B before 0.2.2 still send their own).

[Relay MCP](relay-mcp.md) cannot run members on other machines.
