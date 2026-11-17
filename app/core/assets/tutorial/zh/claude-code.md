---
title: Claude Code
category: 智能体
order: 420
summary: 登录、权限档位、后台任务、压缩对话、额度与保活。
keywords: claude, anthropic, claude code, oauth, keepalive, 保活, compact
---

## 准备

在后端主机安装 Claude Code 并完成登录，确认 `claude` 能正常对话。Relay 用 Claude Agent SDK 为**每个对话**保持一个进程。`RELAY_CLAUDE_BIN` 可以指定可执行文件。

## 控制项

| 控制 | 说明 |
|---|---|
| 模型 | 主模型在第一页，旧版本在「旧版模型」页 |
| 思考强度 | 默认「高」 |
| 权限 | 完全自动（跳过所有检查）、自动接受编辑（默认；其他工具在非交互模式下可能被拦）、仅规划（只读） |
| 快速模式 | 默认关闭 |

改任何设置都会重启这个对话的进程并恢复同一对话，所以下一轮会稍慢。

## 进程与空闲

默认最多保留 3 个 Claude 进程，空闲 15 分钟关闭（`RELAY_CLAUDE_MAX_LIVE`、`RELAY_CLAUDE_IDLE_MS`）。还有后台任务（后台子智能体、Monitor、后台 shell）在跑的进程不会因为空闲被关闭。

## 后台回复

后台工作唤醒 Claude 并写出文字时，单聊会出现一条新回复，可以用「停止」中断，见[发送任务、排队与停止](sending-tasks.md)。

## 压缩对话

输入框 **+** 菜单里的「压缩对话」会发送 `/compact`，见[输入框工具](composer-tools.md)。

## 额度

[额度查询](quota-usage.md)显示五小时和每周额度，输入框上方也会显示剩余额度。可以为下一次五小时重置设置[定时消息](scheduled-messages.md)。

Claude 的五小时窗口只在使用中才计时，过期后接口不再报告重置时间。为此后端默认在窗口空闲时发送一次极小的请求（1 个输出 token）让窗口继续计时。它按普通请求计费、会消耗少量额度；设 `ENABLE_CLAUDE_KEEPALIVE=false` 关闭。额度查询也可能刷新主机上的 OAuth 访问令牌。
