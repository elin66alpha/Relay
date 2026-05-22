# AgentDeck / 智能体工作台

专属 Flutter 聊天客户端 + 本机 Node 后端，用来从一个 app 里切换并调用：

- Claude Code CLI
- Codex CLI
- Antigravity CLI (`agy`)

后端部署在要被控制的电脑上，默认工作目录为 `~/bots_session`（可用 `BOTS_SESSION_DIR` 覆盖）。手机 app 只是壳子：首次打开不会默认连接任何机器，必须扫描这台电脑生成的加密凭证二维码并输入用户设置的密码后才能访问。

当前后端包含以下核心逻辑：

- 三个 agent 平级可选，全部在同一个工作目录内以 bypass 权限运行。
- 每台手机的每个 agent 各保持一条**持久会话**，跨消息保留上下文：Claude 用 `--session-id`/`--resume`、Codex 用 `exec resume`、agy 用 `--conversation`，会话 ID 按 `deviceId:agentKey` 存在 `server/agent-sessions.json`。app 里“清空当前对话”会调用 `/api/session/clear` 同时重置本设备对应 agent 的后端会话。
- Claude Code 和 Codex 使用流式 CLI 输出，后端通过 SSE 把最近步骤和 assistant 文本增量推给 app。
- 同一台手机上的同一 agent 同时只允许一个任务运行；运行中可用输入区停止按钮取消当前任务。
- 单任务默认超时 60 分钟，可用 `AGENT_TIMEOUT_MS` 调整。
- 额度查询统一显示 Claude Code + Codex 两段订阅额度；Antigravity 暂无可查询额度接口。
- 额度刷新通知只监测 Claude Code / Codex 的 5 小时额度清零，基于 utilization 回落判断，不再推周额度。

## 跨平台方向

AgentDeck 的长期形态是「一个私有 agent 控制台」：

1. Android / iOS 手机连接 Linux / macOS / Windows 后端。
2. Linux / macOS / Windows 桌面客户端连接 Linux / macOS / Windows 后端。
3. 后端在各平台作为本机服务运行，负责启动 CLI agents、管理会话、推送流式事件与维护凭证 token。

为了保持高复用，项目边界应固定为：

- **协议层稳定**：HTTP API、SSE 事件、二维码凭证格式、token 吊销机制保持平台无关。
- **Flutter 客户端复用**：聊天、设置、凭证、机器切换、后端 client 逻辑共用；移动端和桌面端只做布局、权限、扫码/导入入口差异。
- **Node 后端复用**：鉴权、会话、SSE、agent 调度主流程共用；平台差异集中到薄适配层，处理工作目录、CLI binary 查找、进程取消、服务自启动、隧道日志和 quota 查询。

## 结构

```text
AgentDeck/
├── lib/                  Flutter 客户端
│   ├── core/backend/     本机后端 HTTP/SSE client
│   ├── core/models/      消息与 CLI agent 模型
│   ├── core/storage/     聊天历史与机器凭证
│   └── features/         聊天、agent 抽屉、机器凭证管理
└── server/               Node 本机后端
    ├── server.js         HTTP API + quota SSE events
    └── lib/              agents（流式执行+持久会话）、tokens（多 token 鉴权/吊销）、
                          workdir、usage、quota-watch、credential-file
```

如果已执行 `flutter build web`，后端会自动托管 `build/web`，可从电脑本机打开 `http://127.0.0.1:8787` 使用 Web 版 app。手机端应通过公网隧道 URL 访问，不要把 `127.0.0.1` 写进手机凭证。

## 后端

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

鉴权 token 全部存在 `server/tokens.json`（每台设备一个、可单独吊销），由 `npm run credential` 生成。后端只接受 `tokens.json` 里未吊销的 token（已移除旧的 `.env` 单 `APP_TOKEN` 兼容项）。`HOST=127.0.0.1` 表示后端只在电脑本机监听，cloudflared/ngrok 这类隧道进程再把它暴露到公网。手机凭证里保存的是公网隧道 URL，不是这台电脑的内网地址。

生成手机凭证（直接运行即可，无需任何参数）：

```bash
cd /path/to/AgentDeck/server
npm run credential
```

脚本会：

- **自动探测公网地址**：从 `agentdeck-tunnel`（cloudflared）的 PM2 日志里读出当前隧道 URL，无需手动 `--url`。
- 提示**设置凭证密码**（至少 6 位，两次确认）。
- 如果 `.env` 没有 `MACHINE_ID` 就生成一个；把 `MACHINE_NAME` / `PUBLIC_BASE_URL` 写入 `.env`。
- 为这份凭证生成一个独立 token 并追加到 `server/tokens.json`。
- **不产出明文凭证文件**，而是输出凭证二维码：保存 PNG 到 `server/credentials/<name>.agentdeck.png`，并直接在终端/SSH 里打印出来供扫描。

凭证二维码里就是加密信封本身（PBKDF2-SHA256 + AES-256-GCM），在 app 里点「扫描二维码」扫入后输入刚设置的密码即可。凭证密码不写入磁盘。新增或吊销 `server/tokens.json` 里的 token 会即时生效。

非交互（如脚本里）可用环境变量传密码：

```bash
AGENTDECK_CREDENTIAL_PASSPHRASE='你的密码' npm run credential
# 隧道未运行或要覆盖时，也可手动指定地址：--url https://你的域名
```

查看或吊销 token：

```bash
npm run credential -- --list-tokens
npm run credential -- --revoke <token-id>
```

隧道说明：

- `ecosystem.config.js` 已包含 `agentdeck-tunnel`，默认用 cloudflared quick tunnel 暴露本机 `http://localhost:8787`。
- quick tunnel 的 URL 可能在重启后变化；要让手机随时随地稳定访问，应在 cloudflared/ngrok 侧配置固定域名或保留域名，再用这个固定 URL 生成凭证。
- 不要把未配置 token 的后端暴露到公网。

HTTP API：

- `GET /api/health`
- `GET /api/status`
- `GET /api/agents`
- `POST /api/chat`，body: `{ "agent": "claude|codex|agy", "prompt": "...", "requestId": "optional" }`
- `POST /api/chat/cancel`，body: `{ "requestId": "..." }`
- `GET /api/usage` 或 `GET /api/usage/:agent`，均返回 Claude Code + Codex 的统一额度报告
- `POST /api/session/clear`，body: `{ "agent": "claude|codex|agy" }`（省略 agent 则清掉全部）。清掉对应 agent 的持久会话，下条消息开新会话，不动工作目录
- `POST /api/workdir/reset`
- `GET /api/events`，SSE 推送 `agent_progress`、`agent_delta`、`agent_cancelled`、`quota_reset` 等事件

PM2 可选：

```bash
cd /path/to/AgentDeck/server
pm2 start ecosystem.config.js
```

`ecosystem.config.js` 里包含 `agentdeck-server` 和 `agentdeck-tunnel`。隧道默认暴露 `http://localhost:8787`。

## Flutter

```bash
cd /path/to/AgentDeck
flutter pub get
flutter run
```

手机 app 不再内置默认后端地址。首次打开会要求**扫描凭证二维码**并输入密码（已移除文件导入）；导入后可以在抽屉里切换多台机器，也可以继续扫码添加新机器。
