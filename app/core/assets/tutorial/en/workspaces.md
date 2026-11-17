---
title: Workspaces
category: Chat
order: 310
summary: What a workspace is, how to switch it, and how it relates to sessions and Swarms.
keywords: workspace, work path, workdir, directory, project, switch, recent
---

A workspace (also called the work path) is a directory **on the backend machine**. Agents read and write files and run commands there.

## Each device picks its own

Each device remembers its own workspace on each backend and sends it with every request. So a phone and a computer can work in different projects on the same machine at once without affecting each other. A new device starts in `~/Relay` on the backend; the deployment can change that with `RELAY_DEFAULT_DIR`.

## The workspace decides what you see

Switching the workspace also switches:

- every agent's session list and chat history
- the Swarm list
- the scope of history search

## How to switch

| Way | Note |
|---|---|
| **Recent workspaces** on Home | up to 5 directories with chat history; tap another one to switch |
| Tags at the top of the file browser | also up to 5, in one horizontally scrolling row; tap to switch and show that directory |
| **Set as work path** in the file browser | after browsing to a new project |

Merely opening another folder in the file browser, or tapping the path bar, does **not** switch the workspace. When browsing elsewhere, tap the **Work path** chip to return to the current project.

While an agent is running the work path cannot change; change it after the turn finishes.

## Opening the file browser

Tap **Current workspace** on Home, the chat title, or **File system** at the bottom of the drawer. See [Browse files and switch disks](file-browser.md).
