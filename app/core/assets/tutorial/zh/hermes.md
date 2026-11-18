---
title: Hermes
category: 智能体
order: 470
summary: 实验性集成：显示主机上配置的模型，权限二选一。
keywords: hermes, provider, yolo, acp, 实验
---

Hermes 是实验性集成。

## 准备

在后端主机安装 Hermes，并用 `hermes model` 配置模型和密钥。Relay 不管理它的密钥。

## 控制项

| 控制 | 说明 |
|---|---|
| 模型 | 只显示主机上配置的那一个模型（用 `hermes config get model.default` 读取）。它只是一个标签，Hermes 始终运行主机配置的模型；要换模型，请在主机上用 `hermes model` 修改 |
| 权限 | 自动批准 yolo（默认）、谨慎（拒绝需要批准的操作，编辑会被拦） |

没有思考强度和快速模式，也不产生后台自动回复。设置直接生效。
