---
title: SSH terminal
category: Machine and tools
order: 730
summary: An interactive terminal from Machine details: resumable sessions, the phone key bar and its permissions.
keywords: ssh, terminal, shell, pty, ctrl, key bar, command line
---

Select **Enter SSH** in [Machine details](machine-details.md) for an interactive terminal on the backend machine. It uses the backend account's login shell and starts in that account's home directory (in `workspace/` for an isolated install). Its colours follow the app's light or dark theme.

## Resumable

Each device token owns one terminal. Going back to Machine details leaves it running, and the next Enter SSH reconnects to it; opening it elsewhere takes it over instead of starting another shell.

A detached terminal is kept for 12 hours with up to 2 MB of output for replay; terminal output is never written to disk. The deployment can tune this with `TERMINAL_IDLE_TIMEOUT_MS` and `TERMINAL_BUFFER_MAX_BYTES`, and pick a shell with `RELAY_TERMINAL_SHELL`.

## The phone key bar

On Android and iOS, in the app or a phone browser, a bar below the terminal adds the keys a phone keyboard lacks: Ctrl, Shift, Esc, Tab and the four arrows.

- Ctrl and Shift apply to the **next** key only: tap Ctrl, then type `c` for Ctrl+C; tap it again to cancel.
- Esc, Tab and the arrows send at once.
- Combinations such as Shift+Tab or Ctrl+Left work as on a hardware keyboard.

## Permissions

The terminal has **every permission** of the backend OS user and is not limited by the file browser's path policy or denylist. Revoking the device token closes its terminal.

## Under the hood

To connect, the app trades its token for a single-use ticket valid for 30 seconds, so the long-lived token never appears in the WebSocket address.
