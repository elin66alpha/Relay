# AgentDeck

[English](README.md) | [路线图](ROADMAP.zh-CN.md)

AgentDeck 是一个私有 CLI 智能体控制台。Flutter 客户端连接运行在你自己机器上的 Node 后端，然后在一个 app 里切换和调用：

- Claude Code CLI
- Codex CLI
- Antigravity CLI (`agy`)

app 不内置任何默认后端地址。首次连接必须扫描后端生成的加密凭证二维码，并输入用户自己设置的密码。

## 设计原则

- 不写死个人主机、路径、token 或凭证。
- 移动端、Web、桌面端和不同后端平台共用同一套 API、凭证和会话模型；操作系统差异只放在安装脚本和适配层里。
- 受保护后端 API 必须使用加密凭证二维码生成的、可吊销的设备 token。
- 安装脚本提供三种网络模式：公网直连、稳定域名的正式 Cloudflare Tunnel，以及快速试用的 Cloudflare Quick Tunnel。

## 当前能力

- 一台后端机器可以在同一个工作路径里暴露 Claude Code、Codex 和 Antigravity。
- **会话按「工作路径 + agent」共享。** 会话身份由 `workdir + agent` 决定，而不是设备。处于同一路径的所有设备共享同一段对话、同一个可续接 CLI 会话与同一份历史，彼此的消息和 agent 的实时进度都会同步镜像。每台设备在本地各自持有当前工作路径（通过 `X-Workdir` 请求头发送），所以两台设备可以同时在不同路径工作、切到同一路径时自动合并。同一共享会话的并发消息会排队串行（底层 CLI 会话不能并发）。
- app 不在本地保存聊天记录。对话由后端（CLI 宿主机）保存，重开 app 时从后端拉回，并自动定位到最新消息而非顶部。清空对话会同时清掉后端历史和该 agent 的可续接会话。
- Claude Code 和 Codex 通过 SSE 流式显示回答。Web 端会对高频流式 UI 更新做节流，避免长回复时界面卡顿。
- assistant 聊天气泡会把 agent 输出按 Markdown 渲染成人类可读格式，包括标题、加粗、
  斜体、列表、引用、代码块和分隔线。`**文字**` 显示为加粗，`*文字*` 显示为斜体，
  行内 code 显示为斜体而不是带背景色的代码样式；同时兼容 `###标题` 这种无空格标题和旧的
  `##文字##` 行内强调。用户自己发送的消息仍按原文显示。
- 长任务可以从 app 中取消。
- 额度查询用弹窗展示，不再写入聊天记录。弹窗显示 Claude Code 和 Codex 的 5 小时剩余额度、本周剩余额度及刷新时间；Antigravity 显示暂未开放。
- 额度刷新提醒走手机系统原生通知（Android / iOS / macOS），发到通知栏而非聊天气泡。依赖 app 进程存活、SSE 在线；app 被系统完全杀掉时收不到（离线远程推送需 FCM/APNs，暂不引入）。
- 工作路径可以从 app 中修改。每台设备在本地各自持有当前路径；后端会校验路径、不存在时让用户确认是否创建。切换路径即把该设备切到对应路径的共享会话。“工作路径”页也会像 `ls` 一样展示目录，文件夹可以点进去以选择更深路径，固定的“上一级”按钮可以一路浏览到系统根目录，文件只展示、不能在这里选择。
- 抽屉里的“文件系统”入口会从当前 workdir 打开，支持上下级目录浏览、下载文件、把文件夹下载为 `.zip`、上传文件；Web 端还支持把文件拖到页面上上传。后端文件 API 被限制在当前 workdir 内。两个目录浏览入口默认隐藏点文件，并提供“显示/不显示隐藏文件”切换。
- 后端受保护 API 在生成至少一个凭证 token 前保持关闭。
- 同一套 Flutter 客户端同时支持移动端、Web 和原生桌面（Windows / macOS / Linux）。窄屏 Web 保持手机式抽屉布局，宽屏 Web 使用常驻侧边栏。桌面构建与打包见 [DESKTOP.md](DESKTOP.md)。
- 压缩按钮会静默执行 agent 的压缩命令，不会把 `/compact` 或 agent 的压缩回复写进当前界面或重开后加载的聊天记录。

## 项目结构

```text
AgentDeck/
├── backends/             不同操作系统的后端安装脚本
│   ├── linux/            基于 PM2 的 Linux 安装入口
│   ├── macos/            基于 LaunchAgent 的 macOS 安装入口
│   └── windows/          基于 PowerShell/计划任务的 Windows 安装入口
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

Windows 使用 PowerShell 后台进程和当前用户计划任务：

```powershell
.\backends\windows\setup.ps1
```

三套安装流程都提供三种网络模式。

- **不用隧穿 / 直连模式**：适用于 VPS 或任何有可达公网 IP/域名的主机。你输入 app 连接地址，后端绑定到 `0.0.0.0`，二维码指向这个地址。暴露到不可信网络前，请在前面配置 HTTPS 反向代理（nginx/Caddy）。
- **Cloudflare Tunnel 模式**：标准 named tunnel 流程，适合你 Cloudflare zone 下的稳定域名。安装脚本可以执行 `cloudflared tunnel login`、创建或复用 named tunnel、运行 `cloudflared tunnel route dns`、写入本地 tunnel config，并用 PM2/LaunchAgent 常驻运行。如果旧的 A/AAAA/CNAME 记录已经占用了这个主机名，脚本会询问是否覆盖成 tunnel DNS route。凭证二维码指向 `https://你的域名`。
- **Cloudflare Quick Tunnel 模式**（默认）：后端继续监听 `127.0.0.1`，cloudflared 运行
  `tunnel --url http://localhost:8787`，凭证二维码指向 cloudflared 打印出来的最新
  `https://*.trycloudflare.com` 地址。这个模式搭建最快，手机不需要和后端在同一网络。Quick Tunnel 地址会在隧道重启后轮换，因此隧道 URL 变化后需要重新生成并导入二维码。

无论哪种方式，在提示时设置一个凭证密码，然后在 app 中导入二维码。

前置要求：Node.js ≥ 18；Linux 安装还需要 `pm2` (`npm install -g pm2`)；Windows 需要 PowerShell；两种 Cloudflare 隧穿模式都需要 `cloudflared`。文件夹下载在 Linux/macOS 上使用系统 `zip` 命令，在 Windows 上使用 PowerShell `Compress-Archive`。

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
AGENTDECK_TUNNEL_MODE=
CLOUDFLARED_BIN=
CLOUDFLARED_ARGS=
AGENTDECK_DEFAULT_DIR=
AGENT_TIMEOUT_MS=3600000
POWERSHELL_BIN=
ENABLE_QUOTA_WATCH=true
QUOTA_POLL_MS=300000
```

Cloudflare Tunnel 和 Quick Tunnel 模式默认使用 `HOST=127.0.0.1`，因为 cloudflared 从本机访问后端。直连模式使用 `HOST=0.0.0.0`，让公网 IP/域名能访问后端。`AGENTDECK_DEFAULT_DIR` 只是**新设备首次启动时的默认路径**（留空则为 `~/agent_deck`）；之后每台设备在本地各自持有当前路径，可在 app 的“工作路径”入口修改。工作路径必须是绝对路径，不接受普通相对路径。

## 创建凭证二维码

先确保后端和所选网络模式已启动（Linux 通常是 `pm2 start ecosystem.config.js`）。

### 方式 A：标准交互式创建（自动探测或读取后端公网地址）
平台安装脚本（类 Unix 主机上的 `backends/*/setup.sh`，Windows 上的
`backends/windows/setup.ps1`）会自动生成二维码。手动创建时，Quick Tunnel 下脚本会自动读取
cloudflared 日志里的最新 `trycloudflare.com` 地址；正式 Cloudflare Tunnel / 直连模式下会使用
`.env` 里的 `PUBLIC_BASE_URL`，并提示你输入密码：
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

### 方式 C：手动指定网址与密码（直连模式 / 使用固定域名）
如果你用直连模式或配了自己的稳定公网域名，可以用这条单行命令直接生成：
```bash
npm run credential -- --passphrase "你的密码" --url "https://你的固定域名"
npm run credential -- --json-out "credentials/machine.agentdeck.json"
```

### 脚本后台执行的操作：
- 自动探测 Quick Tunnel 地址，或读取正式 Cloudflare Tunnel / 直连模式写入的 `PUBLIC_BASE_URL`（除非通过 `--url` 指定）。
- 在缺少 `MACHINE_ID` 时自动生成并写入 `.env` 文件。
- 在 `server/tokens.json` 中生成一个可吊销的、针对该设备的专用 token。
- 删除 `server/credentials/` 里的旧凭证文件，然后在终端输出最新二维码，并同步保存：
  - `server/credentials/<machine>.agentdeck.png`：扫码或上传二维码图片用；
  - `server/credentials/<machine>.agentdeck.json`：打开文件，复制全文，用 app 的“粘贴凭证”导入。

生成新二维码**不会自动吊销已有设备 token**。这是为了避免“给新设备生成二维码”时把已经导入过的手机/Web 端弄成 401。需要停用旧设备时，请手动 `--revoke`。

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
flutter build web --pwa-strategy=none
cd server
npm start
```

当 `build/web/index.html` 存在时，后端会在与 API 相同的主机和端口上提供 Flutter Web 应用。推荐禁用 Flutter service worker，避免浏览器在后端重启后继续加载旧前端代码。

开发时反复执行的构建流程可以直接运行：

```bash
./scripts/build_flow.sh
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
