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
- app 不在本地保存聊天记录。对话由后端（CLI 宿主机）保存，重开 app 时从后端拉回，并自动定位到最新消息而非顶部。清空对话会同时清掉后端历史和该 agent 的可续接会话。
- Claude Code 和 Codex 通过 SSE 流式显示回答。
- 长任务可以从 app 中取消。
- 额度查询用弹窗展示，不再写入聊天记录。弹窗显示 Claude Code 和 Codex 的 5 小时剩余额度、本周剩余额度及刷新时间；Antigravity 显示暂未开放。
- 额度刷新提醒走手机系统原生通知（Android / iOS / macOS），发到通知栏而非聊天气泡。依赖 app 进程存活、SSE 在线；app 被系统完全杀掉时收不到（离线远程推送需 FCM/APNs，暂不引入）。
- 工作路径可以从 app 中修改。后端会校验路径，不存在时让用户确认是否创建，确认后写入 `.env` 持久化；有 agent 任务运行时拒绝切换。
- 后端受保护 API 在生成至少一个凭证 token 前保持关闭。
- 语音输入由 app 录音，发送到后端调用 OpenAI 语音转文字，然后把文字填入输入框，不会自动发送。

## 项目结构

```text
AgentDeck/
├── lib/                  Flutter 客户端
│   ├── core/backend/     后端 HTTP/SSE client
│   ├── core/models/      聊天、CLI agent、机器模型
│   ├── core/storage/     安全存储与本地历史
│   └── features/         聊天、抽屉、凭证、设置、工作路径
└── server/               本机 Node 后端
    ├── server.js         HTTP API + SSE 事件
    └── lib/              agents、tokens、workdir、usage、quota-watch、credentials
```

## 快速开始

最快的方式是运行仓库根目录下的交互式 `setup.sh` 脚本。它会使用 PM2 启动后端，可选择开启隧道，并打印出供 app 扫描的凭证二维码：

```bash
./setup.sh
```

脚本会询问一个问题 —— **你是否需要隧道 (tunnel)？**

- **是** (默认)：通过 cloudflared quick tunnel 暴露 `localhost:8787`。公网 URL 会被自动探测并写入二维码中。需要安装 `cloudflared`。
- **否**：直连模式，适用于 VPS 或任何拥有可达公网 IP/域名的主机。你需要输入 app 应该连接的地址 (例如 `https://agent.example.com` 或 `http://1.2.3.4:8787`)；服务器会绑定到 `0.0.0.0`，且二维码将指向该地址。请在防火墙中放行该端口，并在前面放置一个反向代理来处理 HTTPS。

无论哪种方式，在提示时设置一个凭证密码，然后在 app 中扫描二维码。随时可以重新运行 `./setup.sh` 来重启并重新生成二维码 (quick-tunnel 的 URL 每次重启都会改变)。

前置要求：Node.js ≥ 18，`pm2` (`npm install -g pm2`)，如果使用隧道模式还需 `cloudflared`。

## 手动后端启动

如果你不想使用 `setup.sh`，倾向于自己手动执行步骤：

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
OPENAI_API_KEY=
STT_MODEL=gpt-4o-mini-transcribe
STT_MAX_AUDIO_BYTES=12582912
```

`BOTS_SESSION_DIR` 留空时默认使用 `~/agent_deck`。之后也可以在 app 的“工作路径”入口中修改。工作路径必须是绝对路径，不接受普通相对路径。

语音输入使用后端 `.env` 中的 `OPENAI_API_KEY`。`STT_MODEL` 默认是
`gpt-4o-mini-transcribe`。app 设置里可以选择语音语言：自动、中文、English；默认自动。

## 创建凭证二维码

先启动后端和隧道。仓库里的 PM2 配置会创建一个名为 `agentdeck-tunnel` 的隧道进程。

### 方式 A：标准交互式创建（自动探测隧道网址）
这是最常用的方式，脚本会自动读取 PM2 中 Cloudflare 隧道的日志来探测公网网址，并提示您输入密码：
```bash
cd /path/to/AgentDeck/server
pm2 start ecosystem.config.js
npm run credential
```

### 方式 B：快捷单行命令（仅建议自动化场景）
如果用于自动化，可以直接通过参数传入密码。它不如交互式输入私密，因为 shell 历史或进程列表可能暴露密码：
```bash
npm run credential -- --passphrase "你的密码"
```

### 方式 C：手动指定网址与密码（非 PM2 环境 / 使用固定域名）
如果您未使用 PM2 隧道，或者配置了自己的稳定公网域名，可以使用此单行命令直接生成：
```bash
npm run credential -- --passphrase "你的密码" --url "https://你的固定域名"
```

### 脚本后台执行的操作：
- 自动从 `agentdeck-tunnel` 隧道的 PM2 日志中探测公网地址（除非通过 `--url` 指定）。
- 在缺少 `MACHINE_ID` 时自动生成并写入 `.env` 文件。
- 在 `server/tokens.json` 中生成一个可吊销的、针对该设备的专用 token。
- 在终端输出二维码，并同步保存为 `server/credentials/<machine>.agentdeck.png` 图片。

生成的二维码内容是 PBKDF2-SHA256 + AES-256-GCM 加密后的凭证信封，您的明文密码绝不会写入磁盘。

查看或吊销 token：

```bash
npm run credential -- --list-tokens
npm run credential -- --revoke <token-id>
```

## Flutter 客户端

```bash
cd /path/to/AgentDeck
flutter pub get
flutter run
```

首次打开 app 时，扫描后端二维码并输入凭证密码。之后可以在凭证页面继续添加更多机器。

### APK 签名（开发阶段）

目前没有正式 release 密钥。Android 的 `release` 构建类型复用 debug 签名配置，
因此**我们构建的每个 APK——无论 `flutter build apk`（release）还是 `--debug`——都是
debug 签名的**。这样开发流程更简单，但也意味着在一台机器上构建的 APK 无法覆盖安装由
另一台机器的 `debug.keystore` 签名的版本；遇到这种情况需先卸载旧 app
（`adb uninstall dev.agentdeck.app`），卸载会清空其本地数据。正式对外/上架前再配置
专用 release 密钥。

## API 概览

- `GET /api/health`
- `GET /api/status`
- `GET /api/agents`
- `GET /api/usage`
- `POST /api/stt`
- `GET /api/workdir`
- `POST /api/workdir/check`
- `POST /api/workdir`
- `POST /api/workdir/reset`
- `POST /api/chat`
- `POST /api/chat/cancel`
- `POST /api/session/clear`
- `GET /api/events`

所有 `/api/*` 路由都需要 `Authorization: Bearer <token>`。如果后端还没有生成任何 token，受保护 API 会返回 `TOKEN_NOT_CONFIGURED`，不会以未鉴权状态运行。
