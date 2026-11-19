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

To update the backend see [Update the backend](backend-update.md). For what each version changes, see What's new on Home.
