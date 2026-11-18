---
title: Relay 是什么
category: 入门
order: 110
summary: Relay 的组成、数据流向，以及它能做什么、不能做什么。
keywords: 介绍, 架构, 后端, 客户端, 隐私, overview
---

Relay 把你**自己机器上**的 CLI 智能体（Claude Code、Codex、Cursor、OpenCode、Antigravity、Hermes）变成一个可以从手机、网页或电脑打开的聊天工作台。

## 两个部分

| 部分 | 运行在哪里 | 作用 |
|---|---|---|
| Relay 后端 | 你的电脑或服务器（Node.js 22+） | 启动并保持各个 CLI 的会话，管理文件、终端、浏览器和额度 |
| Relay 客户端 | 手机（Android、iOS）、网页、桌面（Windows、macOS、Linux） | 聊天界面；所有操作都通过后端完成 |

客户端通过带令牌的 HTTP 和 SSE 连接后端。没有 Relay 云账号，也没有中转服务器：源码、终端权限和 CLI 登录信息都留在后端机器上。

## 关键概念

- **机器**：一个后端。客户端可以导入多台机器的凭证并随时切换，见[导入凭证与管理机器](import-credential.md)。
- **工作区（工作路径）**：后端上的一个目录，智能体在这里干活。每台设备在每台机器上各自记住自己的工作区，见[工作区](workspaces.md)。
- **会话**：同一工作区、同一智能体下最多 8 个命名对话，见[会话](sessions.md)。
- **蜂群**：多个智能体在同一份记录里分工协作，见[创建蜂群](swarm-basics.md)。

一个对话由「工作区 + 智能体 + 会话」唯一确定。不同对话可以同时运行，互不干扰；在同一个对话里连续发送的消息会排队依次执行。

## Relay 不是沙箱

智能体和终端拥有后端操作系统用户的全部权限。Relay 只限制文件浏览器能看到的路径，不限制智能体本身。请用权限受限的普通用户运行后端，详见[安全须知](security.md)。

## 下一步

1. [部署后端](deploy-backend.md)
2. [导入凭证与管理机器](import-credential.md)
3. [第一次任务](first-task.md)
