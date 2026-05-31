# AgentDeck

[English](README.md) | [路线图](ROADMAP.zh-CN.md)

AgentDeck 是一个私有 CLI 智能体控制台。Flutter 客户端连接运行在你自己机器上的 Node 后端，然后在一个 app 里切换和调用：

- Claude Code CLI
- Codex CLI
- Antigravity CLI (`agy`)

app 不内置任何默认后端地址。首次连接必须扫描后端生成的加密凭证二维码，并输入用户自己设置的密码。

## 设计原则

这些原则指导 AgentDeck 的每一个决策；新功能和新平台都必须遵守。

1. **面向产品级，而非个人玩具。** 所有东西都要对**所有用户**开箱即用，而不只是在作者本人的"一台电脑 + 一部手机"上能跑。不写死地址，不做"在我机器上能用"的假设。
2. **普世、多平台。** 一等支持移动端（Android/iOS）、Web、桌面（Windows/macOS/Linux）客户端，以及 Linux/macOS/Windows 后端。平台差异放进 adapter 层，不污染核心。
3. **干净优雅优先于权宜。** 宁可选稳定、自解释、可维护的方案，也不要只图快的接法。
4. **默认私有。** 后端暴露的是一个能力很强的 agent shell，不该裸露在公网。网络走私有 mesh（Tailscale），流量端到端加密，只在你自己的 tailnet 内可达。
5. **不依赖临时/试用基础设施。** 地址和入口必须跨重启稳定。正常路径下绝不依赖会轮换的免费试用隧道或其他"尽力而为"的服务。

## 当前能力

- 一台后端机器可以在同一个工作路径里暴露 Claude Code、Codex 和 Antigravity。
- **会话按「工作路径 + agent」共享。** 会话身份由 `workdir + agent` 决定，而不是设备。处于同一路径的所有设备共享同一段对话、同一个可续接 CLI 会话与同一份历史，彼此的消息和 agent 的实时进度都会同步镜像。每台设备在本地各自持有当前工作路径（通过 `X-Workdir` 请求头发送），所以两台设备可以同时在不同路径工作、切到同一路径时自动合并。同一共享会话的并发消息会排队串行（底层 CLI 会话不能并发）。
- app 不在本地保存聊天记录。对话由后端（CLI 宿主机）保存，重开 app 时从后端拉回，并自动定位到最新消息而非顶部。清空对话会同时清掉后端历史和该 agent 的可续接会话。
- Claude Code 和 Codex 通过 SSE 流式显示回答。
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

两套安装流程都提供两种网络模式。

- **Tailscale 模式**（推荐，默认）：后端通过你自己的 [Tailscale](https://tailscale.com) tailnet 访问。二维码默认写入稳定的 `100.x` Tailscale IPv4，因为即使手机客户端没有启用 MagicDNS 也能用；如果客户端 DNS 支持，MagicDNS（`http://<机器名>.<tailnet>.ts.net:8787`）也可以。地址跨重启不变，流量端到端加密（WireGuard），能穿透 NAT/CGNAT，且后端**完全不暴露在公网**。需要在宿主机和每个客户端设备上安装 Tailscale（一次安装并登录同一账号）。
  - 同一路由器/公网 IP 后面的两台后端，各自拿到独立且稳定的 tailnet 地址、永不冲突——Tailscale 地址是按设备分配的，与你的局域网或公网 IP 无关。
  - 想要"仅 tailnet 可达 + HTTPS"，可运行 `tailscale serve --bg 8787`，再用得到的 `https://…ts.net` 网址重新生成二维码。
- **直连模式**：适用于 VPS 或任何有可达公网 IP/域名的主机。你输入 app 连接地址，后端绑定到 `0.0.0.0`，二维码指向这个地址。暴露到不可信网络前，请在前面配置 HTTPS 反向代理（nginx/Caddy）。

无论哪种方式，在提示时设置一个凭证密码，然后在 app 中导入二维码。

前置要求：Node.js ≥ 18；推荐模式还需要 [Tailscale](https://tailscale.com/download)（Linux 用 `curl -fsSL https://tailscale.com/install.sh | sh`，macOS 用 `brew install tailscale`，然后 `sudo tailscale up`）。Linux 安装还需要 `pm2` (`npm install -g pm2`)。文件夹下载依赖系统 `zip` 命令，Linux/macOS 通常自带；如果你的主机镜像没有，需要自行安装。

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
HOST=0.0.0.0
MACHINE_ID=
MACHINE_NAME=
PUBLIC_BASE_URL=
AGENTDECK_DEFAULT_DIR=
AGENT_TIMEOUT_MS=3600000
ENABLE_QUOTA_WATCH=true
QUOTA_POLL_MS=300000
```

`HOST=0.0.0.0` 让 Tailscale 接口能访问后端，tailnet 本身保证其私有性。`AGENTDECK_DEFAULT_DIR` 只是**新设备首次启动时的默认路径**（留空则为 `~/agent_deck`）；之后每台设备在本地各自持有当前路径，可在 app 的“工作路径”入口修改。工作路径必须是绝对路径，不接受普通相对路径。

## 创建凭证二维码

先确保 Tailscale 已连接（`tailscale status`）并已启动后端（`pm2 start ecosystem.config.js`）。

### 方式 A：标准交互式创建（自动探测 Tailscale 地址）
最常用方式，脚本会自动探测本机的 Tailscale IPv4 地址（MagicDNS 作为兜底），并提示你输入密码：
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
```

如果你确定所有客户端的 Tailscale DNS 都正常，也可以显式使用 MagicDNS：
```bash
npm run credential -- --url "http://你的机器名.tailnet.ts.net:8787"
```

### 脚本后台执行的操作：
- 自动探测本机的 Tailscale 地址（除非通过 `--url` 指定）。
- 在缺少 `MACHINE_ID` 时自动生成并写入 `.env` 文件。
- 在 `server/tokens.json` 中生成一个可吊销的、针对该设备的专用 token。
- 删除 `server/credentials/` 里的旧二维码图片，然后在终端输出最新二维码，并同步保存为 `server/credentials/<machine>.agentdeck.png` 图片。

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
