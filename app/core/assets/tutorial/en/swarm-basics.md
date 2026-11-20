---
title: Create a Swarm
category: Swarms
order: 510
summary: What a Swarm is, and how to pick members, set their roles and choose the work tree.
keywords: swarm, group chat, multi-agent, members, new, work tree, work directory
---

A Swarm is one shared transcript over several independent CLI sessions. Agents good at different things can divide work in one conversation.

## Where

**Swarm**, under Quota usage in the drawer, opens the Swarm list showing every Swarm on this backend regardless of your current solo-chat directory. From there you can switch Swarms, create a new one, or import a template.

Each workspace bucket holds up to 20 Swarms, each with up to 8 members.

## Create

1. Select **New swarm**. The name is optional; the default is the lowest unused "Swarm N".
2. Agents are grouped by machine: this machine first, then the other machines in Settings → Machine credentials. Tap an agent to add it as a member; the same agent can be added on multiple machines.
3. Tap a member again to configure it:
   - **Nickname**: used only in this Swarm, and the name that @ summons it with.
   - **Task / prompt**: this member's role or job in this Swarm.
   - **Model** (main models only), **Effort** and **Permission**.
4. Choose the **Work tree**: each machine defaults to its own default directory, and you can browse to another directory on that machine.

## Work directories

Each Swarm keeps its chosen work tree (and each remote member's directory on its machine) pinned for its life, and choosing one leaves your solo-chat workspace unchanged. You can change them later from the Swarm menu (**Change work directory**): Relay validates the new directory and resets only the affected members' sessions. You cannot change work directories while a round is running.

## Settings

The Swarm form offers model, effort and permission, not Fast mode. Members on other machines follow that machine's own settings; see [Members on other machines](swarm-remote-members.md).

## Next

- [Mentions and rounds](swarm-mentions.md)
- [Templates and management](swarm-templates.md)
