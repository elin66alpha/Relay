---
title: Create a Swarm
category: Swarms
order: 510
summary: What a Swarm is, and how to pick members, set their roles and choose the work tree.
keywords: swarm, group chat, multi-agent, members, new, work tree, work directory
---

A Swarm is one shared transcript over several independent CLI sessions. Agents good at different things can divide work in one conversation.

## Where

**Swarm**, under Quota usage in the drawer, shows how many Swarms the current workspace has. It opens the Swarm list, where you can create a Swarm or import a template.

Each workspace holds up to 20 Swarms, each with up to 8 members.

## Create

1. Select **New swarm**. The name is optional; the default is "Swarm N".
2. Agents are grouped by machine: this machine first, then the other machines in Settings → Machine credentials. Tap an agent to add it as a member; the same agent can be added more than once.
3. Tap a member again to configure it:
   - **Nickname**: used only in this Swarm, and the name that @ summons it with.
   - **Task / prompt**: this member's role or job in this Swarm.
   - **Model** (main models only), **Effort** and **Permission**.
4. Choose the **Work tree**: the current workspace by default, or another directory.

## The work tree is fixed

The work tree is part of the Swarm transcript's key and of each member's session, so it **cannot change** after creation. Choosing it also leaves this device's current workspace unchanged.

The Swarm is listed under the current workspace, while its members run in the work tree it chose.

## Settings

The Swarm form offers model, effort and permission, not Fast mode. Members on other machines follow that machine's own settings; see [Members on other machines](swarm-remote-members.md).

## Next

- [Mentions and rounds](swarm-mentions.md)
- [Templates and management](swarm-templates.md)
