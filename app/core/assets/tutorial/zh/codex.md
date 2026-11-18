---
title: Codex
category: 智能体
order: 430
summary: 登录方式、沙箱权限、子智能体回复、模型目录与额度。
keywords: codex, openai, chatgpt, app-server, 沙箱, sandbox, 子智能体
---

## 准备

在后端主机安装 Codex（`npm install -g @openai/codex`）并登录。Relay 支持 Codex 的几种认证方式：ChatGPT 账号登录、API key、外部令牌，以及主机上配置的 provider。`CODEX_HOME` 可以指定配置目录。

所有 Codex 对话共用一个 `app-server` 进程。

## 控制项

| 控制 | 说明 |
|---|---|
| 模型 | 来自已安装 CLI 的模型目录，保持它的顺序和默认值；旧版本在「旧版模型」页 |
| 思考强度 | 随模型变化，默认「中」 |
| 权限 | 工作区可写（默认；网络和工作区外路径受限）、只读、完全访问（无沙箱） |
| 快速模式 | 默认关闭 |

Codex 在所有档位都关闭审批，沙箱就是全部边界。模型、思考和快速模式每轮生效；改沙箱会重新打开对话，但仍是同一对话。

## 重新检查

在[机器详情](machine-details.md)点「重新检查」时，Relay 会实际验证 Codex 的登录并尝试刷新。账号缺失或刷新被拒会显示为需要登录；临时的探测失败显示为检查错误。

## 子智能体与后台工作

Codex 子智能体完成时的回复会出现在单聊里。Relay 只为自己的 Codex 进程开启相关实验功能，不修改主机上的 Codex 配置。

Codex 的沙箱会在每条命令返回时结束它的进程组，所以后台进程只有脱离成独立会话（`setsid`）才能存活。

## 额度

[额度查询](quota-usage.md)显示五小时和每周额度；可以设置[定时消息](scheduled-messages.md)。查询额度会发送一个极小的请求以获取限额信息，可能消耗少量额度。更新 Codex 后模型目录会刷新。
