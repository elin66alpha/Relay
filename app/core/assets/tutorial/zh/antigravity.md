---
title: Antigravity
category: 智能体
order: 450
summary: agy 的安装登录、独立会话、模型与思考、权限、额度池。
keywords: antigravity, agy, gemini, google, argon, acp, 额度
---

## 准备

1. 在后端主机安装支持 `agy acp --process-per-session` 的新版 `agy`。
2. 运行 `agy acp --login` 登录。
3. 重启 Relay 后端，并在[机器详情](machine-details.md)里重新检查状态。

Windows 的 Setup 也可以安装 Antigravity。

## 会话

每个对话有独立的会话进程，所以多个对话可以同时运行，各自的模型和设置互不影响。回复实时显示，并复用存活的会话；会话被回收后会自动恢复保存的对话。

## 控制项

| 控制 | 说明 |
|---|---|
| 模型 | 来自 `agy models`，后端启动时和打开选择页时（最多十分钟一次）刷新 |
| 思考强度 | 同一模型的多个强度变体合并成一个模型，强度单独选择，从低到高排列 |
| 权限 | 谨慎（默认，拒绝需要批准的请求）、自动批准 |

## 后台回复

定时器、子智能体或后台命令唤醒 Antigravity 并写出回复时，会出现在单聊里，可以用「停止」中断。

## 上下文

上下文用量从 Antigravity 的语言服务器读取，见[上下文用量](context-usage.md)。

## 额度

[额度查询](quota-usage.md)显示订阅额度，Gemini、Claude/GPT 和 Argon 各自单独显示；输入框上方只显示一行提示，指向额度查询。

有正在运行的 Antigravity 对话时，额度立即返回；否则 Relay 运行一次 `agy -p /usage`（约两秒，不消耗模型调用）。结果缓存五分钟。Antigravity 不支持定时消息。

## 删除与安全

删除 Relay 里的会话会关闭它的存活会话并忘记 ID；`agy` 自己的对话记录仍由主机上的 CLI 管理。Antigravity 的登录文件不能通过文件浏览器读取。
