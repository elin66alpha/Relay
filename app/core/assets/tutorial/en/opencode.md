---
title: OpenCode
category: Agents
order: 460
summary: An experimental integration: provider setup on the host, the model list and permissions.
keywords: opencode, provider, big-pickle, acp, experimental
---

OpenCode is an experimental integration.

## Preparation

Install OpenCode on the backend host and configure a provider there (`~/.config/opencode/opencode.json` or `opencode auth login`). An API key is optional and managed on the host.

All OpenCode conversations share one ACP process; each session carries its own workspace.

## Controls

| Control | Note |
|---|---|
| Model | from `opencode models`: OpenCode's free models (decided on OpenCode's side, so they change) plus each provider you configured on the host, labelled with the model name over its provider. Before the first list it offers `big-pickle` |
| Effort | supported |
| Permission | Bypass (default), Ask (anything needing approval is refused; edits may be blocked) |

Settings apply directly without restarting the process. There is no Fast mode and no background replies.

The model list refreshes at backend start, after a CLI update and when the picker opens (at most every ten minutes), and is kept in `server/reported-models.json`.
