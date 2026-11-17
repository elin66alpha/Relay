---
title: Composer tools: attach, clear, compress, export
category: Chat
order: 350
summary: Attach file, Clear chat, Compress and Export Markdown in the composer's + menu.
keywords: attachment, upload, clear, compress, compact, export, markdown, menu, attach
---

Tap the **+** left of the composer. The first row holds the model and other controls (see [Model, effort, permission and Fast mode](agent-controls.md)); the second holds these tools.

## Attach file

Pick one or more files, even while a turn is running. Each file uploads to `.relay/uploads/` in the workspace, with a `yyyyMMdd-HHmmss-` prefix from the device's local time. After each upload its workspace-relative path is appended to the draft; you send when ready.

Note: these files show up in the repository's `git status` unless `.relay/` is ignored. Each file is limited to 100 MB by default.

## Clear chat

Deletes the session's chat history and resets the machine-side session: a fresh start. It asks first and is unavailable while a turn runs.

## Compress

Asks the agent to compress the conversation into a summary (it sends `/compact`), freeing context while the conversation continues. When it finishes, "Conversation compacted" appears in the chat and [Context usage](context-usage.md) updates. Support depends on the CLI; Claude Code supports it natively. Unavailable while a turn runs.

## Export Markdown

Saves the current conversation to the device as a Markdown file. Common token patterns are redacted first, but that is not a general secret scanner.
