# AgentDeck

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
- assistant 聊天气泡会把 agent 输出按 Markdown 渲染成人类可读格式，包括标题、加粗、
  斜体、列表、引用、代码块和分隔线。`**文字**` 显示为加粗，`*文字*` 显示为斜体，
  行内 code 显示为斜体而不是带背景色的代码样式；同时兼容 `###标题` 这种无空格标题和旧的
  `##文字##` 行内强调。用户自己发送的消息仍按原文显示。
- 长任务可以从 app 中取消。
- 额度查询用弹窗展示，不再写入聊天记录。弹窗显示 Claude Code 和 Codex 的 5 小时剩余额度、本周剩余额度及刷新时间；Antigravity 显示暂未开放。
- 额度刷新提醒走手机系统原生通知（Android / iOS / macOS），发到通知栏而非聊天气泡。依赖 app 进程存活、SSE 在线；app 被系统完全杀掉时收不到（离线远程推送需 FCM/APNs，暂不引入）。
- 工作路径可以从 app 中修改。后端会校验路径，不存在时让用户确认是否创建，确认后写入 `.env` 持久化；有 agent 任务运行时拒绝切换。“工作路径”页也会像 `ls` 一样展示目录，文件夹可以点进去以选择更深路径，固定的“上一级”按钮可以一路浏览到系统根目录，文件只展示、不能在这里选择。
- 抽屉里的“文件系统”入口会从当前 workdir 打开，支持上下级目录浏览、下载文件、把文件夹下载为 `.zip`、上传文件；Web 端还支持把文件拖到页面上上传。后端文件 API 被限制在当前 workdir 内。两个目录浏览入口默认隐藏点文件，并提供“显示/不显示隐藏文件”切换。
- 后端受保护 API 在生成至少一个凭证 token 前保持关闭。
- 同一套 Flutter 客户端同时支持移动端、Web 和原生桌面（Windows / macOS / Linux）。窄屏 Web 保持手机式抽屉布局，宽屏 Web 使用常驻侧边栏。桌面构建与打包见 [DESKTOP.md](DESKTOP.md)。
- 压缩按钮会静默执行 agent 的压缩命令，不会把 `/compact` 或 agent 的压缩回复写进当前界面或重开后加载的聊天记录。

## 项目结构

```text
AgentDeck/
├── backends/             不同操作系统的后端安装脚本
│   ├── linux/            基于 PM2 的 Linux 安装入口
│   └── macos/            基于 LaunchAgent 的 macOS 安装入口
├── lib/                  Flutter 客户端
│   ├── core/backend/     后端 HTTP/SSE client
│   ├── core/models/      聊天、CLI agent、机器模型
│   ├── core/storage/     安全存储与设备标识
│   └── features/         聊天、抽屉、凭证、设置、工作路径、文件系统、卡片
└── server/               本机 Node 后端
    ├── server.js         HTTP API + SSE 事件
    └── lib/              agents、tokens、workdir、usage、quota-watch、credentials
```

## 后端快速开始

Linux 使用现有的 PM2 后端安装流程：

```bash
./backends/linux/setup.sh
```

macOS 使用 LaunchAgent 管理服务，不依赖 PM2：

```bash
./backends/macos/setup.sh
```

两套安装流程都支持隧道模式和直连模式。

- **隧道模式**（默认）：通过 cloudflared quick tunnel 暴露 `localhost:8787`。脚本自动探测公网 URL 并写入二维码。
- **直连模式**：适用于 VPS、局域网主机，或任何有可达 IP/域名的主机。你输入 app 连接地址，后端绑定到 `0.0.0.0`，二维码指向这个地址。暴露到不可信网络前，请在前面配置 HTTPS 反向代理。

无论哪种方式，在提示时设置一个凭证密码，然后在 app 中导入二维码。quick tunnel 的 URL 重启后会变化，因此重启 quick tunnel 后需要重新生成二维码。

前置要求：Node.js ≥ 18。Linux 安装还需要 `pm2` (`npm install -g pm2`)；两端使用隧道模式都需要 `cloudflared`。文件夹下载依赖系统 `zip` 命令，Linux/macOS 通常自带；如果你的主机镜像没有，需要自行安装。

仓库根目录旧的 `./setup.sh` 仍保留为 Linux 可用的快捷入口。

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
```

`BOTS_SESSION_DIR` 留空时默认使用 `~/agent_deck`。之后也可以在 app 的“工作路径”入口中修改。工作路径必须是绝对路径，不接受普通相对路径。

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

首次打开 app 时，导入后端凭证并输入凭证密码。移动端可以用摄像头扫描二维码。Web 和桌面端（Windows/macOS/Linux）通过粘贴加密二维码内容或上传保存下来的二维码图片导入，并刻意隐藏摄像头扫码（桌面无 mobile_scanner 实现）。之后可以在凭证页面继续添加更多机器。

Web 凭证通过 Flutter 的 Web 安全存储后端持久化在浏览器本地存储中，因此连接私人机器时请使用私人的浏览器配置。

构建 Web 前端并让 Node 后端托管它：

```bash
cd /path/to/AgentDeck
flutter build web
cd server
npm start
```

当 `build/web/index.html` 存在时，后端会在与 API 相同的主机和端口上提供 Flutter Web 应用。

开发时反复执行的“老流程”可以直接运行：

```bash
./scripts/old_flow.sh
```

它会依次执行 Flutter analysis/test、Node 语法检查、构建 Web、重启 PM2 后端、等待 Web
端点可访问、构建 Android debug APK，并用 `adb install -r` 安装到手机。

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
- `GET /api/auth/status`
- `GET /api/usage`
- `GET /api/workdir`
- `GET /api/workdir/browse`
- `POST /api/workdir/check`
- `POST /api/workdir`
- `POST /api/workdir/reset`
- `GET /api/fs/list`
- `GET /api/fs/download`
- `POST /api/fs/upload`
- `POST /api/chat`
- `POST /api/chat/cancel`
- `GET /api/history`
- `POST /api/session/clear`
- `GET /api/events`

所有 `/api/*` 路由都需要 `Authorization: Bearer <token>`。如果后端还没有生成任何 token，受保护 API 会返回 `TOKEN_NOT_CONFIGURED`，不会以未鉴权状态运行。
