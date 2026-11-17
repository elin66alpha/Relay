---
title: Search history and export
category: Chat
order: 380
summary: Search every session's history in the current workspace, jump to a match, and export a conversation.
keywords: search, history, export, record
---

## Search

Tap the search button at the top of the chat screen. By default it searches the history of every agent and session in the **current workspace**; check **Current agent only** to narrow it.

It returns at most 50 matches. Tap one to jump to that session with the message highlighted.

## Export

Choose **Export Markdown** in the composer's **+** menu to export the current conversation; see [Composer tools](composer-tools.md).

## Where history lives

Chat history is stored on the backend in `server/chat-history.json`, keeping the latest 200 messages of each conversation or Swarm. The file is **not encrypted** and can contain prompts, agent output and project content; protect it and its backups like the backend account.

Search snippets and exports redact common token patterns but never change the stored history.
