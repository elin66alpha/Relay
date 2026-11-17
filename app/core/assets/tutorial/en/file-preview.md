---
title: File preview
category: Files
order: 620
summary: Read-only previews of text, code, Markdown and images, and their size limits.
keywords: preview, image, markdown, code, highlighting, source, 512 KiB
---

Tap a file in the file browser to open a read-only preview.

| Type | Preview | Limit |
|---|---|---|
| UTF-8 text | the first 512 KiB, with a notice when cut | |
| Code | supported languages are syntax-highlighted | highlighted up to 20,000 characters, plain text beyond |
| Markdown (`.md`, `.markdown`) | rendered by default; the toolbar button toggles **View source** | embedded images are not loaded; over 20,000 characters it opens as source |
| Images (JPG, PNG, WebP, GIF, BMP, ICO) | zoomable viewer | up to 20 MiB and 40 million pixels |

Binary files (with NUL bytes or invalid UTF-8) and malformed or oversized images cannot be previewed.

Previews use the download route, so its path policy and size limit apply. The preview's download button saves the full file.

File links in chat replies open this preview too; see [Copy, Edit and links](messages-and-links.md).
