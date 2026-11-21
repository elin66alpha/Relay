---
title: Upload and download
category: Files
order: 630
summary: Upload files, drag and drop, download files and zipped folders, and the size limits.
keywords: upload, download, zip, drag and drop, size limit
---

## Upload

Select **Upload file** in the file browser; files go into **the directory shown**. On the Web you can also drag files onto the page.

Each file is limited to 100 MB by default (`UPLOAD_MAX_BYTES`). Files attached in chat upload to `.relay/uploads/` in the workspace; see [Composer tools](composer-tools.md).

## Download

Both files and folders can be downloaded. Folders are zipped: with the host's `zip` command on Linux and macOS, with PowerShell on Windows. A folder that contains a denied path is refused as a whole.

One download (zipped folders included) is limited to 300 MB by default (`DOWNLOAD_MAX_BYTES`).

Progress shows while downloading, and the location when done:

| Platform | Location |
|---|---|
| Web | the browser's downloads folder (large files may use a lot of memory) |
| iOS | the app's Documents folder, under Files → On My iPhone → Relay |
| Android 10 and later | the Download folder |
| Android 9 and earlier | `Android/data/dev.relay.app/files/Download` in internal storage |
| Others | the path shown in the message |
