---
title: Copy, Edit and links
category: Chat
order: 360
summary: Copying messages, putting your own message back in the draft, and file and web links in replies.
keywords: copy, edit, link, file link, url, select text
---

## Copy and Edit

Every settled message offers:

- **Copy**: copies it to the clipboard. An agent reply copies its final answer.
- **Edit** (your own messages only): puts the message's text back in the composer for you to revise and send. It changes no history and sends nothing on its own.

You can also long-press or drag to select text in a message.

## Links in replies

In finished solo-chat replies, Markdown links are tappable:

| Link | Does |
|---|---|
| A file path (absolute, or relative to the workspace) | opens the file preview; a directory opens the file browser |
| A web address (`http`, `https`, `mailto`) | first shows the full address, and opens it in the system browser only after you confirm |

A `:42` or `#L42` line suffix on a path is ignored. File access follows the file API's path policy; see [File access: open or isolated](file-access-mode.md).

Other schemes do nothing; plain-text paths that are not Markdown links stay text; links in Swarm chats do not open.
