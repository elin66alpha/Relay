---
title: 后端配置项
category: 部署后端
order: 250
summary: server/.env 中最常用的设置：地址、默认目录、超时、会话上限、额度和推送。
keywords: env, .env, 配置, 环境变量, PORT, HOST, RELAY_DEFAULT_DIR, AGENT_TIMEOUT_MS, 设置
---

后端设置在 `server/.env`，完整说明见 `server/.env.example`。改完后重启后端（Linux：`pm2 restart relay-server --update-env`）。

## 身份与网络

| 变量 | 说明 |
|---|---|
| `PORT` | 监听端口，默认 `8787` |
| `HOST` | 监听地址；隧道或同机反向代理时保持 `127.0.0.1` |
| `PUBLIC_BASE_URL` | 写进凭证的地址，必须和客户端导入的完全一致 |
| `MACHINE_ID`、`MACHINE_NAME` | 机器标识和名称，由 `npm run credential` 填写 |
| `RELAY_SERVE_WEB` | 设为 `0` 时不提供网页客户端 |
| `CORS_ALLOW_ORIGIN` | 网页客户端来源固定时可收窄跨域 |

## 执行

| 变量 | 说明 |
|---|---|
| `RELAY_DEFAULT_DIR` | 新设备的默认工作区，默认 `~/Relay` |
| `AGENT_TIMEOUT_MS` | 单轮最长时间，默认 60 分钟 |
| `PROMPT_MAX_BYTES` | 单条消息上限 |
| `RELAY_TERMINAL_SHELL` | SSH 终端使用的 shell |
| `TERMINAL_IDLE_TIMEOUT_MS`、`TERMINAL_BUFFER_MAX_BYTES` | 断开后终端保留多久、保留多少输出 |
| `RELAY_BROWSER` | 内置浏览器使用的 Chrome / Chromium / Edge 路径 |
| `CODEX_HOME` | Codex 的配置目录 |

## 智能体会话

为节省资源，空闲会话会被关闭，并限制同时存活的数量。默认最多 3 个 Claude 进程、每个其他智能体 4 个会话，空闲 15 分钟关闭；超过上限的轮次会排队等待。会话被关闭后，下一轮会自动恢复同一对话，只是稍慢。

| 变量 | 默认 |
|---|---|
| `RELAY_CLAUDE_MAX_LIVE` | 3 |
| `RELAY_CLAUDE_IDLE_MS` | 900000 |
| `RELAY_AGENT_MAX_SESSIONS` | 4 |
| `RELAY_AGENT_IDLE_MS` | 900000 |
| `RELAY_SWARM_MAX_HOPS` | 3，见[@召唤与轮次](swarm-mentions.md) |

## 文件

`RELAY_WORKSPACE_ROOT`、`RELAY_FS_ROOTS` 见[文件访问：开放与隔离](file-access-mode.md)；`UPLOAD_MAX_BYTES`、`DOWNLOAD_MAX_BYTES` 默认 100 MB 和 300 MB。

## 额度

| 变量 | 说明 |
|---|---|
| `ENABLE_QUOTA_WATCH` | 监视额度窗口重置，用于提醒和定时消息 |
| `QUOTA_POLL_MS` | 轮询间隔 |
| `ENABLE_CLAUDE_KEEPALIVE` | 保持 Claude 五小时窗口持续计时，见[定时消息](scheduled-messages.md) |
| `CLAUDE_KEEPALIVE_MODEL` | 保活请求使用的模型 |

## 离线推送

`VAPID_PUBLIC_KEY`、`VAPID_PRIVATE_KEY`、`VAPID_SUBJECT` 用于网页推送；`FCM_SERVICE_ACCOUNT_FILE` 用于 Android FCM。见[通知](notifications.md)。
