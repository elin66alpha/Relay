---
title: Cursor
category: 智能体
order: 440
summary: agent 命令与登录、付费模型页、按模型分进程、额度池。
keywords: cursor, agent, agent login, CURSOR_API_KEY, acp, 付费模型, composer
---

## 准备

Cursor 的 CLI 命令是 **`agent`**，不是 `cursor`。在后端主机运行 `agent login`，或者设置 `CURSOR_API_KEY`。

Relay 通过 ACP 驱动 Cursor，并使用自己的配置目录 `server/cursor-config/`，所以在 Relay 里选的模型**不会**改动你主机上 `~/.cursor` 的默认设置。登录仍然使用主机的 `agent login`。

## 控制项

| 控制 | 说明 |
|---|---|
| 模型 | 默认 Auto。第二页「需要支付方式的模型」是套餐包含用量以外的模型（Auto、Grok、Composer 以外），从第一次请求就扣预付费用量 |
| 思考强度 | 每个模型有自己的档位 |
| 权限 | 完全自动（默认）、仅规划（只读）、只问答（只读） |
| 快速模式 | 只有带快速选项的模型才有 |

模型列表在后端启动、更新 CLI 后，以及打开选择页时（最多十分钟一次）刷新。第一次拿到列表之前，或者 Cursor 没登录时，只提供 Auto。

## 按模型分进程

Cursor 把模型、思考强度和速度应用到整个进程，所以每种组合运行在单独的 Cursor 进程里（选择相同的对话共用一个）。切换设置时，对话会在对应进程里恢复。

## 限制

- Cursor 不报告上下文用量，选中时不显示[上下文用量](context-usage.md)。
- 不产生后台自动回复。
- 删除会话时，Relay 自己删除 `server/cursor-config/acp-sessions/` 下对应的目录，因为 Cursor 没有删除命令。

## 额度

[额度查询](quota-usage.md)从 Cursor 控制台读取包含用量，查询本身不消耗用量。X 系列套餐（如 Premium）是一个每周用量池；旧套餐分为「Cursor 模型」和「其他模型（API）」两个池。Cursor 的重置不支持定时消息。
