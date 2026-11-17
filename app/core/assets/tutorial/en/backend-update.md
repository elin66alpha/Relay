---
title: Update the backend
category: Backend setup
order: 260
summary: Update and restart the backend from the app, or upgrade it by hand on the host.
keywords: update, upgrade, version, restart, self-update
---

## From the app

Open [Machine details](machine-details.md). The **Relay backend** row shows the backend's version. When a newer release exists it offers **Update to \<version\> and restart**.

After you confirm, the backend downloads the latest release and restarts. **Running turns and terminals are interrupted**, so wait for tasks to finish first. The update keeps `server/.env`, tokens, chats and settings.

It uses the same upgrade path as the host: the installed `scripts/install/unix/update.sh` on Linux and macOS, `update.cmd` on Windows. Its output goes to `relay-update.log` in the OS temp directory.

The app cannot update a backend when:

- it runs from a git checkout (update it with `git pull` yourself), or
- an update was already started within the last ten minutes.

## On the host

| OS | Command |
|---|---|
| Linux / macOS | run `./scripts/install/unix/update.sh` in the Relay folder |
| Windows | run `.\update.cmd` in the Relay folder |

For an installation from 0.1.12 or earlier, extract the new archive to a separate directory. From that new folder run `RELAY_DIR="/absolute/path/to/existing/relay" ./scripts/install/unix/update.sh`, substituting the existing installation path.

## Client versions

To update the app itself see [Update the app](app-update.md). A newer client can use an older backend; when the backend lacks a newer route, the app says the backend is too old.
