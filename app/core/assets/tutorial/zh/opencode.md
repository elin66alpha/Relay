---
title: OpenCode
category: 智能体
order: 460
summary: 实验性集成：主机上的 provider 配置、模型列表与权限。
keywords: opencode, provider, big-pickle, acp, 实验
---

OpenCode 是实验性集成。

## 准备

在后端主机安装 OpenCode，并在那里配置 provider（`~/.config/opencode/opencode.json` 或 `opencode auth login`）。API key 可选，由主机管理。

所有 OpenCode 对话共用一个 ACP 进程，每个会话携带自己的工作区。

## 控制项

| 控制 | 说明 |
|---|---|
| 模型 | 来自 `opencode models`：OpenCode 的免费模型（由 OpenCode 那边决定，会变化），加上你在主机上配置的每个 provider 的模型，标签显示「模型名 / provider」。第一次拿到列表前提供 `big-pickle` |
| 思考强度 | 支持 |
| 权限 | 完全自动（默认）、询问（需要批准的操作被拒绝，编辑可能被拦） |

设置直接生效，不重启进程。没有快速模式，也不产生后台自动回复。

模型列表在后端启动、更新 CLI 后和打开选择页时（最多十分钟一次）刷新，保存在 `server/reported-models.json`。
