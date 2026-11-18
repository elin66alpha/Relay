---
title: Machine details
category: Machine and tools
order: 710
summary: Hardware, the backend version and update, Enter SSH, CLI status, device tokens and diagnostics.
keywords: machine details, hardware, cpu, memory, gpu, temperature, disk, status, diagnostics
---

Tap the machine card on Home or in the drawer to open Machine details, where everything about one backend comes together.

## Hardware

The CPU model and thread count, memory, GPU, each local disk's used / total space, and mainboard, SSD, CPU and GPU temperatures (each the average of its sensors). It refreshes every 10 seconds while open, and says so when no temperature sensor is readable.

## Relay backend

Shows the backend's version; when a newer release exists you can update and restart it in one step; see [Update the backend](backend-update.md).

## Enter SSH

Opens an interactive terminal on this machine; see [SSH terminal](ssh-terminal.md).

## CLI agents

Each agent's installed, login and usable state, plus **Recheck**; see [Agent status and sign-in](agent-status.md).

## Device tokens

Every device's token, who uses it, when it was created and last used, with Revoke and Delete; see [Device tokens](device-tokens.md).

## Status

The backend's diagnostics: the work directory (whether it exists and is writable), system and process uptime, public URL, runtime, listening address, each CLI check, and the state of the storage files. Look here first when the connection or an agent misbehaves; see [Troubleshooting](troubleshooting.md).
