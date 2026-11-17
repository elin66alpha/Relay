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

In the Swarm form, other machines' agents are listed after this machine's, labelled with the machine's name, for example `Claude Code (Studio)`. Adding one checks that B is reachable and has that agent, then creates a dedicated session on B named `Swarm: <swarm name>`. B's previous active session is restored afterwards.

A remote member sets only its **nickname, prompt and work directory on B** (by default the one the app remembers for B), and the work directory is fixed once added. Model, effort and permission follow that session's settings on B.

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

B sees these as ordinary turns from this device. If no device has that work directory open on B, B sends its own task notifications.

[Relay MCP](relay-mcp.md) cannot run members on other machines.
