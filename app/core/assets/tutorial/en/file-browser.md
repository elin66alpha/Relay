---
title: Browse files and switch disks
category: Files
order: 610
summary: The path bar, going up, switching disks, hidden files, new folders and Set as work path.
keywords: file system, file browser, path, disk, drive, hidden files, new folder, parent, UNC
---

## Open it

Tap **Current workspace** on Home, **File system** at the bottom of the Workspaces page that the chat title opens, or **File system** at the bottom of the drawer.

## Navigate

- The **path bar** always stays above the list. Tap any ancestor segment to jump there.
- Go up one directory with the up arrow, the `..` row at the top of the list, or a **right swipe** on the file list.
- The current work path is marked when it appears in a listing.
- When browsing elsewhere, tap the **Work path** chip to return to the current project.
- The row of tags at the top holds up to 5 recent workspaces; tap one to switch the workspace and show that directory.

A Windows network share path (UNC, such as `\\server\share`) keeps the server and share together as one root.

## Switch disks

When the backend has more than one disk, the first path segment shows a ▾ that opens a disk menu:

- Windows: the drive letters, such as `C:\` and `D:\`.
- macOS and Linux: `/` plus each mounted disk (`/Volumes/…`, `/media/…`), the same disks Machine details lists.

An isolated install offers no disk menu. A disconnected network drive cannot hold up a listing.

## Buttons

- App bar: **Show / Hide hidden files** and **Refresh** (also retries a failed first load).
- Below the path bar: **Set as work path**, **New folder** and **Upload file** (see [Upload and download](upload-download.md)).

## Set as work path

After browsing to a project, select **Set as work path** to make it this device's workspace on this machine; see [Workspaces](workspaces.md). Check the displayed directory before uploading too.

## Which directories you can see

The backend decides: the built-in denylist always applies, and the deployment can narrow access with `RELAY_FS_ROOTS` or an isolated install; see [File access: open or isolated](file-access-mode.md).
