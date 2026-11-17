---
title: Where your data lives
category: Advanced
order: 1030
summary: What the backend and the device each store, and what must never be committed or shared.
keywords: data, privacy, history, storage, backup, file locations, tokens.json
---

Relay has no cloud; all data lives on your backend and your devices.

## On the backend (under `server/`)

| Data | Note |
|---|---|
| `.env` | deployment settings |
| `tokens.json`, `credentials/` | device tokens and exported credentials |
| `chat-history.json` | chat history, the latest 200 messages per conversation, **not encrypted** |
| sessions, settings, Swarms | named sessions, per-session settings, Swarm configuration |
| `agent-sessions.json` | each CLI's conversation resume ids |
| `context-windows.json`, `reported-models.json` | context window sizes and the model list cache |
| `cursor-config/` | Relay's own Cursor configuration |
| quota state, scheduled messages, usage cache | |
| push subscriptions, FCM devices | |

Each CLI also keeps its own login and transcripts on the host, managed by the CLI.

All of this is **deployment state** and can contain prompts, code and account details. Never commit it to git or put it in a shared archive, and protect backups like the backend account.

## On the device

- Machine credentials: platform secure storage on native apps, browser site storage on the Web.
- Each machine's current workspace, theme, language, font size and notification switches.
- The wallpaper image (never uploaded).

## Deleting

Deleting a session removes Relay's history and resume id and asks the CLI to delete its transcript, which depends on the CLI; for guaranteed erasure check the CLI's data on the host. Uninstall scripts keep configuration, tokens, credentials and history for you to clean up by hand.
