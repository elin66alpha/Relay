---
title: Update the app
category: App settings
order: 930
summary: Check for updates at start-up or in About, and download and install a new version on each platform.
keywords: update, upgrade, version, download, install, apk, release
---

## Checking

- At start-up, when a newer version exists, a dialog offers to download and install it.
- Or check by hand in **Settings → About → Check for updates**.

The app compares itself with the latest release on GitHub.

## How each platform installs

| Platform | How |
|---|---|
| Android | downloads the APK and opens the system installer |
| Windows | replaces the app's files and restarts |
| Linux | downloads the `.deb` and opens it in the software installer |
| macOS | unpacks the new app in Downloads |
| iOS | reports the new version; install it from TestFlight |
| Web | updates with its backend |

On Windows, versions 0.2.0 and 0.2.1 close when you choose Update and reopen on the old version. Install 0.2.2 by hand once: download `relay-client-windows-x64-v0.2.2.zip` from GitHub Releases, quit Relay, and unpack it over the app's folder. If an update fails later, the reason is in `relay-client-update.log` in the temp folder (`%TEMP%`).

To update the backend see [Update the backend](backend-update.md). For what each version changes, see What's new on Home.
