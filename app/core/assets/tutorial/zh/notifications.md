---
title: 通知
category: 用量与通知
order: 830
summary: 任务完成和额度重置提醒，以及各平台在后台、关闭后能否收到。
keywords: 通知, 推送, notification, push, fcm, web push, 提醒, 任务完成
---

## 两种提醒

在「设置 → 通知」里分别开关：

| 开关 | 何时提醒 |
|---|---|
| 任务完成提醒 | 一轮结束，而**没有设备**正在看那个工作区时；内容是回复的第一行 |
| 额度刷新提醒 | 额度窗口重置时 |

## 各平台

| 平台 | 能力 |
|---|---|
| Android、iOS、macOS、Windows | App 在接收实时事件时显示本地通知 |
| 网页 | 浏览器通知；部署方配置 Web Push 后，关闭标签页也能收到 |
| Android | 部署方配置 FCM 后，App 被杀掉也能收到 |
| Linux 桌面 | 只在 App 内提示 |

完全关闭的 iOS App 目前没有离线推送通道。

## 部署方配置

- Web Push：在 `server/.env` 设置 `VAPID_PUBLIC_KEY`、`VAPID_PRIVATE_KEY`、`VAPID_SUBJECT`。
- FCM：设置 `FCM_SERVICE_ACCOUNT_FILE`，并使用配置了 Firebase 的 Android 构建。

服务账号文件和推送令牌都是部署机密，不要提交到仓库。
