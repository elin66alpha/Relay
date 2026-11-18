---
title: Demo mode
category: Getting started
order: 115
summary: Explore Relay's interface and simulated chat replies before deploying a backend.
keywords: demo, try, preview, offline, simulate, backend
---

If you do not have a Relay backend running yet, **Demo mode** lets you explore the app right away with no server or network connection.

## Entering Demo mode

1. On the initial welcome screen (when no machine credential has been imported yet), select **Try the demo**.
2. Relay activates a built-in simulated machine (`Relay Demo`). Chats and backend responses stay on your device. The demo skips automatic release checks and push registration.

A **Demo mode** banner stays visible at the top of the screen while the demo machine is active.

## What works in Demo mode

- **Home, drawer, and solo chat**: browse the workspace overview, open **Claude Code** or **Codex**, pick models/effort/permission controls, and send messages to see streamed demo replies.
- **Machine details & Quota usage**: view sample hardware metrics and quota meters.

Because there is no host backend, **File attachments**, **SSH terminal**, **Browser**, file browsing, and Swarms cannot connect to real tools—**Enter SSH** and **Browser** are disabled in Demo mode, and unavailable backend operations report that they are not available in demo mode.

## Leaving Demo mode

- Select **Exit demo** in the **Demo mode** banner to remove the demo machine and return to the initial credential screen.
- Or open **Settings → Machine credentials → Add machine** and import a real machine credential—importing a real machine automatically removes the demo machine.

When you are ready to run real agents, follow [Deploy the backend](deploy-backend.md) and [Import a credential and manage machines](import-credential.md), or use the GitHub contact link on the welcome screen or in **Settings → About** to ask the author about a ready-made backend.
