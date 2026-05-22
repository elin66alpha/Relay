# AgentDeck / 智能体工作台

[English](README.md) | [路线图](ROADMAP.zh-CN.md)

AgentDeck 是一个私有 CLI 智能体控制台。Flutter 客户端连接运行在你自己机器上的 Node 后端，然后在一个 app 里切换和调用：

- Claude Code CLI
- Codex CLI
- Antigravity CLI (`agy`)

app 不内置任何默认后端地址。首次连接必须扫描后端生成的加密凭证二维码，并输入用户自己设置的密码。

## 当前能力

- 一台后端机器可以在同一个工作路径里暴露 Claude Code、Codex 和 Antigravity。
- 每台设备的每个 agent 都有隔离的持久会话。
- Claude Code 和 Codex 通过 SSE 流式显示回答。
- 长任务可以从 app 中取消。
- 额度查询用弹窗展示，不再写入聊天记录。弹窗显示 Claude Code 和 Codex 的 5 小时剩余额度、本周剩余额度及刷新时间；Antigravity 显示暂未开放。
- 工作路径可以从 app 中修改。后端会校验路径，不存在时让用户确认是否创建，确认后写入 `.env` 持久化；有 agent 任务运行时拒绝切换。

## 项目结构

```text
AgentDeck/
├── lib/                  Flutter 客户端
│   ├── core/backend/     后端 HTTP/SSE client
│   ├── core/models/      聊天、agent、机器模型
│   ├── core/storage/     安全存储与本地历史
│   └── features/         聊天、抽屉、凭证、设置、工作路径
└── server/               本机 Node 后端
    ├── server.js         HTTP API + SSE 事件
    └── lib/              agents、tokens、workdir、usage、quota-watch、credentials
```

## 后端启动

```bash
cd /path/to/AgentDeck/server
npm install
cp .env.example .env
npm start
```

主要环境变量：

```dotenv
PORT=8787
HOST=127.0.0.1
MACHINE_ID=
MACHINE_NAME=
PUBLIC_BASE_URL=
BOTS_SESSION_DIR=
AGENT_TIMEOUT_MS=3600000
ENABLE_QUOTA_WATCH=true
QUOTA_POLL_MS=300000
```

`BOTS_SESSION_DIR` 留空时默认使用 `~/bots_session`。之后也可以在 app 的“工作路径”入口中修改。工作路径必须是绝对路径，不接受普通相对路径。

## 创建凭证二维码

先启动后端和隧道。仓库里的 PM2 配置会创建一个名为 `agentdeck-tunnel` 的隧道进程。

```bash
cd /path/to/AgentDeck/server
pm2 start ecosystem.config.js
npm run credential
```

凭证脚本会：

- 从 `agentdeck-tunnel` 的 PM2 日志里自动读取公网隧道 URL。
- 提示用户设置凭证密码并二次确认。
- 在缺少 `MACHINE_ID` 时自动创建，并更新 `.env`。
- 在 `server/tokens.json` 中创建一个可吊销 token。
- 在终端打印二维码，并保存为 `server/credentials/<machine>.agentdeck.png`。

非交互运行：

```bash
AGENTDECK_CREDENTIAL_PASSPHRASE='你的密码' npm run credential
npm run credential -- --url https://你的固定域名
```

查看或吊销 token：

```bash
npm run credential -- --list-tokens
npm run credential -- --revoke <token-id>
```

二维码内容是 PBKDF2-SHA256 + AES-256-GCM 加密后的凭证信封。凭证密码不会写入磁盘。

## Flutter 客户端

```bash
cd /path/to/AgentDeck
flutter pub get
flutter run
```

首次打开 app 时，扫描后端二维码并输入凭证密码。之后可以在凭证页面继续添加更多机器。

## API 概览

- `GET /api/health`
- `GET /api/status`
- `GET /api/agents`
- `GET /api/usage`
- `GET /api/workdir`
- `POST /api/workdir/check`
- `POST /api/workdir`
- `POST /api/workdir/reset`
- `POST /api/chat`
- `POST /api/chat/cancel`
- `POST /api/session/clear`
- `GET /api/events`

生成凭证后，所有 `/api/*` 路由都需要 `Authorization: Bearer <token>`。
