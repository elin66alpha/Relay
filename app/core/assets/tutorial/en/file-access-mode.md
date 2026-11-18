---
title: File access: open or isolated
category: Backend setup
order: 240
summary: The file access choice at setup, RELAY_FS_ROOTS, and the sensitive paths that are always protected.
keywords: isolated, open, workspace, RELAY_WORKSPACE_ROOT, RELAY_FS_ROOTS, permissions, sensitive files, denylist
---

## The two setup choices

| Choice | Effect |
|---|---|
| **Open** (default) | agents and the file browser reach every file the backend user can |
| **Isolated** | workspaces, the file browser and SSH's starting directory stay inside `workspace/` in the install directory, and agents lose their full-auto / unsandboxed permission tier |

Isolated writes `RELAY_WORKSPACE_ROOT` to `server/.env`. Reinstalling offers the current choice as the default; Service status shows it as `File access`. Uninstall keeps `workspace/` and its files.

> Isolated is Relay's own path policy, **not an operating-system sandbox**. Agent CLIs and the terminal still run as the backend user.

In isolated mode the file browser offers no disk menu.

## Narrowing further: RELAY_FS_ROOTS

Set `RELAY_FS_ROOTS` in `server/.env` to the absolute directories the file API may reach. Without it, the file API can reach the whole filesystem except the built-in denylist below.

## Paths that are always denied

In every mode, the file browser, previews and downloads cannot read:

- Relay's token file, `.env`, the generated credential directory, push token stores, and the FCM service-account key
- `~/.ssh`
- Claude Code's OAuth credentials, Codex's login file, Cursor's `auth.json`, Antigravity's login files, and Relay's own Cursor config directory `server/cursor-config/`
- copies of those names followed by a dot, such as `.env.bak-x` and `tokens.json.bak`

A folder download that would contain a denied path is refused as a whole.

The list is not a general secret scanner and does not cover every third-party CLI's configuration. In production, combine it with `RELAY_FS_ROOTS` and a restricted user; see [Security](security.md).
