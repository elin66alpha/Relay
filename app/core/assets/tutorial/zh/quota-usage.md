---
title: 额度查询
category: 用量与通知
order: 810
summary: Claude Code、Codex、Cursor、Antigravity 的额度卡片，以及输入框上方的额度条。
keywords: 额度, 用量, quota, usage, 5 小时, 每周, 重置, 限额
---

## 打开

侧边栏的「额度查询」。

## 卡片

每个来源单独查询，哪个先返回就先显示，不用等其他卡片。

| 来源 | 显示 |
|---|---|
| Claude Code | 5 小时和本周剩余额度、重置时间；可设置定时消息 |
| Codex | 5 小时和本周剩余额度、重置时间；可设置定时消息 |
| Cursor | X 系列套餐（如 Premium）一个每周池；旧套餐分「Cursor 模型」和「其他模型」两个池 |
| Antigravity | Gemini、Claude/GPT、Argon 各自的订阅额度 |

卡片上的提示：

- **截至 …**：数据时间。
- **上次成功结果**：最新一次查询失败，显示的是之前的结果。
- **配额窗口已重置，等待最新数据**：窗口刚重置。

额度显示和[机器详情](machine-details.md)里的登录状态是分开的。

## 输入框上方的额度条

单聊时，输入框上方显示当前智能体的剩余额度（Claude Code、Codex、Cursor）。切换智能体时和每轮结束后更新，每个智能体最多一分钟一次，与后端的一分钟缓存一致。Antigravity 只显示一行提示，请到额度查询里看。

## 注意

- 查询可能读取并刷新主机上的 OAuth 访问令牌，但令牌值不会发给 App。
- Codex 查询会发一个极小的请求获取限额信息，可能消耗少量额度。
- Claude 默认开启保活，见[定时消息](scheduled-messages.md)。
- Antigravity 没有运行中的对话时会运行一次 `agy -p /usage`，结果缓存五分钟。

额度重置时的提醒见[通知](notifications.md)。
