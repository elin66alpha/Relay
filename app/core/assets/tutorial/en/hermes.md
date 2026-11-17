---
title: Hermes
category: Agents
order: 470
summary: An experimental integration: shows the model configured on the host, two permission tiers.
keywords: hermes, provider, yolo, acp, experimental
---

Hermes is an experimental integration.

## Preparation

Install Hermes on the backend host and configure its model and key with `hermes model`. Relay does not manage its key.

## Controls

| Control | Note |
|---|---|
| Model | shows only the one model configured on the host (read with `hermes config get model.default`). It is a label: Hermes always runs the host's configured model. To change models, use `hermes model` on the host |
| Permission | Auto-approve yolo (default), Cautious (refuses anything that needs approval; edits are blocked) |

There is no effort control, no Fast mode and no background replies. Settings apply directly.
