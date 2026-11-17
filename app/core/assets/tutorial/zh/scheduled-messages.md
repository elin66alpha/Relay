---
title: 定时消息
category: 用量与通知
order: 820
summary: 在下一次五小时额度重置时自动发送一条提示词；以及 Claude 保活。
keywords: 定时消息, 预约, schedule, 重置, 五小时, keepalive, 保活
---

额度用完时，可以预约一条消息，在下一次**五小时窗口重置**时自动发出，让工作接着进行。只支持 Claude Code 和 Codex。

## 设置

1. 打开[额度查询](quota-usage.md)。
2. 在 Claude Code 或 Codex 卡片上点「定时消息」。
3. 输入消息内容并保存。

每个来源、每个工作区保存**一条**消息。卡片上显示发送时间和内容预览；在同一个对话框里可以修改，或点「清除已排程」取消。

## 发到哪里

消息发到设置时的工作区和会话。如果那个会话在发送前被删除，这条定时消息就会失败。发出的一轮和普通消息一样出现在聊天里，并标注是额度重置后发送的。

## 依赖后端监视额度

定时消息需要后端开启额度监视（`ENABLE_QUOTA_WATCH`，默认开启）。Cursor 和 Antigravity 的重置不会触发定时消息。

## Claude 保活

Claude 的五小时窗口只在使用中才计时，空闲过期后接口不报告重置时间，App 只能显示未知。为了让窗口持续计时，后端默认在窗口空闲时发送一次极小的 Claude Code 请求（1 个输出 token），然后等到下一次重置之后。

它按普通请求计费、会消耗少量额度。在 `server/.env` 设 `ENABLE_CLAUDE_KEEPALIVE=false` 可以关闭；`CLAUDE_KEEPALIVE_MODEL` 指定保活使用的模型。
