# WORK.md — AI Agent 工作记录

> 本文件是所有 AI agent 在本仓库（AgentDeck）改动的**共享工作日志**。
> 目的：让接手的 agent 能快速搞清楚“之前的 agent 改了什么、为什么这么改、改在哪里”，
> 而不必从头通读全部代码或 git 历史。

## 写法约定（给后续 agent）

- **每完成一段工作就在「工作记录」顶部追加一条**（最新的在最上面）。
- 一条记录包含：日期、对应的 commit（若已提交）或标注「未提交」、改动摘要、涉及文件、为什么这么做。
- 描述「意图和取舍」，不要照抄 diff——diff 用 `git show <hash>` 就能看。
- 已提交的内容以 git 为准；本文件只做导读和背景说明。
- 不要把密钥、token、明文凭证写进本文件。

## 项目速览

AgentDeck = Flutter 客户端 + Node.js 后端，用来远程控制本机的 CLI agent
（Claude Code、Codex、Antigravity `agy`）。关键设计：

- 客户端不内置后端地址，靠扫描**加密凭证二维码**（PBKDF2-SHA256 + AES-256-GCM）首次连接。
- 受保护接口用**可吊销的设备 bearer token**鉴权（`server/tokens.json`，0o600）；没有任何 token 时返回 `TOKEN_NOT_CONFIGURED`，不存在免鉴权回退。
- 助手文本通过 **SSE** 流式返回。
- 工作目录默认 `~/agent_deck`（`BOTS_SESSION_DIR`）。
- 详细文档见 `README.md` / `README.zh-CN.md`，规划见 `ROADMAP.md`。

---

# 工作记录（最新在最上）

## 2026-05-23 — 桌面前端 Windows/macOS（Flutter 原生）【未提交】

需求：把 Windows / macOS 前端做出来。经确认用 **Flutter 原生桌面**（不套壳 web），
本机（Linux）**不**真正构建 Linux 成品，重点是把 Win/macOS 工程配好 + 文档。

**核查结论**：项目本就是 Flutter，`windows/`、`macos/`、`linux/` 三个原生工程都在；
不需要 Electron/Tauri。Windows 工程已品牌化好（窗口标题/ProductName=AgentDeck、
company dev.agentdeck、图标、binary agentdeck.exe），基本无需改。

**硬约束**（已写进文档）：桌面成品不能交叉编译——Windows 必须在 Windows+VS 构建，
**macOS 必须在 Mac+Xcode 构建**，这台 Linux 都做不出来。

**macOS 修复（关键）** —— 之前 macOS 工程虽品牌化（`Configs/AppInfo.xcconfig`:
PRODUCT_NAME=AgentDeck、bundle id `dev.agentdeck.app`，无需改），但有两个会导致
Release 不可用的问题：
- `Runner/DebugProfile.entitlements` + `Runner/Release.entitlements`：加
  `com.apple.security.network.client`。sandbox 开着却没这条 → Release 版**连不上
  后端**（任何网络请求被拒）。这是必修项。
- `Runner/Info.plist`：加 `NSAppTransportSecurity > NSAllowsLocalNetworking`，让
  本地明文 `http://LAN-IP:port` 直连后端可用（公网 cloudflared https 本就放行）。

**客户端加固**：
- `machine_credentials_screen.dart`：相机扫码守卫从 `!kIsWeb` 收紧为**仅
  android/iOS**（`defaultTargetPlatform`）。`mobile_scanner` 无 Windows/Linux 实现，
  桌面/Web 一律隐藏摄像头扫码，改用「上传二维码图片 / 粘贴凭证」。

**插件桌面兼容性核查**（决定能否构建）：
- `generated_plugins`（windows/linux）干净：`mobile_scanner` 在 Win/Linux 被自动
  排除 → 构建不会因它失败；`flutter_secure_storage`/`flutter_local_notifications`
  在 Windows 有实现。
- `notification_service.dart` 已守卫：仅 android/iOS/macOS 调用通知，Win/Linux
  自动降级为 app 内系统消息（不会崩）。

**文档**：
- 新增 `DESKTOP.md`（英文）：前置依赖、各 OS 构建/运行命令、产物路径、桌面连接方式
  （无相机扫码、用上传/粘贴）、已知限制、macOS 签名/公证、Windows 打包、各平台已配置项。
- `README.md` / `README.zh-CN.md`：平台描述加入「原生桌面 Windows/macOS/Linux」+ 指向
  DESKTOP.md；凭证导入说明补充桌面端用上传/粘贴。

**验证**：`flutter analyze lib/` No issues。**无法在本机（Linux）构建 Windows/macOS
验证**——需在对应 OS 上 `flutter build windows` / `flutter build macos` 实测。

**涉及文件**：`macos/Runner/DebugProfile.entitlements`、`macos/Runner/Release.entitlements`、
`macos/Runner/Info.plist`、`lib/features/machines/machine_credentials_screen.dart`、
`DESKTOP.md`(新)、`README.md`、`README.zh-CN.md`、`WORK.md`。

## 2026-05-23 — macOS 后端平台入口（已提交 73d510c）

- 保留 `server/` 作为共享 Node 后端核心，新增 `backends/` 区分平台安装脚本。
- `backends/linux/setup.sh` 封装现有 Linux/PM2 安装流程。
- `backends/macos/` 新增 LaunchAgent 方案：`setup.sh`、`start.sh`、`stop.sh`、
  `status.sh`、`uninstall.sh` 和共享 `lib/common.sh`。后端服务 label 为
  `dev.agentdeck.backend`，隧道服务 label 为 `dev.agentdeck.tunnel`。
- macOS setup 支持 cloudflared quick tunnel 和直连模式，会生成/更新 `server/.env`，
  安装 npm 依赖，启动服务，从日志识别 `trycloudflare.com` 地址，并用 `--url` 生成凭证二维码。
- 由于当前环境不是 macOS，本次只能做 shell 语法和现有 Node/Flutter 验证；launchd 行为仍需
  在真实 macOS 上测试。

## 2026-05-23 — 去除语音输入 / OpenAI STT【未提交，待真机测试】

- 用户确认 OpenAI STT 不再使用。已移除聊天输入栏麦克风按钮、设置页语音语言选项、
  Flutter 录音抽象、后端 `/api/stt`、OpenAI STT 环境变量、平台麦克风权限与相关依赖。
- `server/.env` 不再需要 `OPENAI_API_KEY`、`STT_MODEL`、`STT_MAX_AUDIO_BYTES`。
- README / ROADMAP / 当前 API 总览同步删除语音输入说明。

## 2026-05-23 — 聊天优化 + 移除输入框 "/" 菜单 + 静默压缩【未提交，待真机测试】

**滚动动画卡顿（移动 + Web）**
- `bot_chat_screen.dart`：流式回复期间不再每次通知都 `animateTo`。现在每帧最多一次
  `jumpTo`，用户上滑读历史时不强行拉到底，仅在贴底或新增消息时跟随。

**Web 回复后输入框失焦**
- `bot_chat_screen.dart` `_InputBar.didUpdateWidget`：Web 上一轮回复结束后重新聚焦输入框；
  移动端不主动弹软键盘。

**移除输入框 "/" 菜单**
- 后端非交互模式（`claude --print` / `codex exec`）不能可靠转发交互式 slash 指令。
  额度、清空、压缩已由明确按钮覆盖，因此删除输入框里的 slash 弹出菜单，避免误导。

**去除模型选择残留**
- 上次实现后又决定不保留模型选择。当前代码已删除聊天页入口、后端 `/api/chat` 参数、
  agent 启动参数、相关 i18n 文案。

**静默压缩**
- 压缩按钮调用 `/api/chat` 时传 `recordHistory:false`，仍向当前 agent 发送 `/compact`，
  但不在聊天界面插入用户消息、也不保存 agent 的压缩回复。完成后只弹出“压缩完成”确认框。

## 2026-05-23 — 未登录态适配（前后端，移动+Web）

**背景**：此前聊天主链路完全不感知 agent CLI 的登录态——某个平台没登录时，CLI 的
登录错误会被当成「助手的回复」以 HTTP 200 返回，甚至被 `appendHistory` 当成功轮次
写进 `chat-history.json`。唯一沾边的只有额度弹窗（`usage.js`，且 agy 连这都没有）。
本次只补后端。

**改动**
- `server/lib/agents.js`：
  - 新增 `AgentAuthError`（`code: 'NOT_LOGGED_IN'`, 带 `agent`）和启发式
    `isAuthError(text)`（匹配 not logged in / please log in / run `<cli> login` /
    /login / unauthorized / invalid api key 等；**刻意只匹配鉴权类**，不会误吞
    resume 的「session not found」消息）。
  - claude/codex/agy 三个 `finalize`：当没有可用输出且文本像登录错误时，返回
    `{ __authError: true }`，在各自 `.then()` 里抛 `AgentAuthError`。agy 原来直接
    `return spawnStream(...)`，这次补了 `.then()` 包装。
  - 导出 `AgentAuthError`。
- `server/server.js`：`/api/chat` 的 catch 里新增 `NOT_LOGGED_IN` 分支——
  - 非流式：返回 **HTTP 424**（避开 401=坏设备 token、503=TOKEN_NOT_CONFIGURED），
    body `{error, code:'NOT_LOGGED_IN', agent}`；
  - 流式：发 SSE `agent_error` 事件并带 `code:'NOT_LOGGED_IN'`（流式响应头已 200 发出，
    无法再改状态码）；通用流式 `agent_error` 也顺手带上 `code: err.code`。
  - 因为现在是「抛异常」而不是返回内容，未登录的回合**不再写进 `chat-history.json`**。
- 新增 `server/lib/auth-status.js` + `GET /api/auth/status`：只读凭证文件、不 spawn CLI，
  返回每个 agent 的 `loggedIn`（claude/codex 可判 true/false；agy 无可靠凭证文件，返回
  `null` 表示未知）。供 app 在发消息前提示。

**客户端（移动 + Web，纯 Material/跨平台，无平台专属 API）**
- `lib/core/backend/backend_client.dart`：
  - 流式 `agent_error` 现在读取并透传 `code`（之前只取 `error`、丢弃 code），
    `NOT_LOGGED_IN` 映射为 `BackendException(status:424, code:'NOT_LOGGED_IN')`。
  - 新增 `fetchAuthStatus()` → 调 `GET /api/auth/status`，返回 `Map<String,bool?>`。
- `lib/features/chat/bot_chat_controller.dart`：
  - 新增 `_authStatus` + `agentLoggedIn(key)` getter + `refreshAuthStatus()`（best-effort，
    失败不影响聊天）；`loadFor` 切换上下文时 `unawaited(refreshAuthStatus())`。
  - `_runTurn` catch 识别 `code=='NOT_LOGGED_IN'`，显示本地化文案
    `agentNotLoggedIn(label)`，并立即把该 agent 标记为未登录以更新横幅。
    **不阻断发送**——检测是 best-effort，真失败仍由这条回退路径兜底。
- `lib/features/chat/bot_chat_screen.dart`：聊天列表上方新增 `_NotLoggedInBanner`
  （`errorContainer` 配色 + 锁图标 + 「重新检查」按钮调 `refreshAuthStatus`），
  仅当 `agentLoggedIn(key)==false` 显示（agy 为 null/未知时不显示）。
- `lib/core/i18n/app_strings.dart`：新增 `agentNotLoggedIn` / `agentNotLoggedInBanner` /
  `recheck` 三个中英文案。

**验证**：
- 后端：`node -c` 三文件通过；`isAuthError` 单测正确区分鉴权错误 vs resume/正常回复；
  本机 boot 测 `GET /api/auth/status` 返回 `claude:true, codex:true, agy:null`；测试端口
  已清理无残留 tunnel。
- 客户端：`flutter analyze lib/` No issues；`flutter build web` ✓；
  `flutter build apk --debug` ✓（移动 + Web 两个目标都编译通过）。

## 2026-05-22 — 聊天记录从「本地」改为「后端持久化」

**意图**：app 不再在本地保存聊天记录。对话由后端（CLI 宿主机）保存，app 重开时
从后端拉回，并自动定位到最新一条消息（而不是停在列表顶部）。清空对话时同时清掉
后端历史和该 agent 的可续接 CLI 会话，保证两者一致。

**后端**
- 新增 `server/lib/history.js`：按 `scopeKey`（`deviceId:agentKey`，与 `agents.js`
  的会话 key 一致）存储对话到 `server/chat-history.json`（0o600）。每个会话上限
  `MAX_PER_SCOPE = 200` 条，防止文件无限增长。导出 `readHistory / appendHistory / clearHistory`。
- `server/server.js`：
  - `POST /api/chat` 成功后用 `appendHistory` 记录这一轮的 user+assistant 消息
    （**只记成功的轮次**，取消/失败的不记）；user 与 assistant 共用同一 `createdAt`。
  - 新增 `GET /api/history?agent=<key>`：返回该设备+agent 的历史 `messages`。
  - `POST /api/session/clear`：在清 CLI 会话的同时调用 `clearHistory`（单 agent 和全部 agent 两条路径都加了）。
- `server/.gitignore`：忽略 `chat-history.json`。

**客户端**
- 删除 `lib/core/storage/chat_history_store.dart`（基于 SharedPreferences 的本地历史，已废弃）。
- `lib/core/backend/backend_client.dart`：新增 `fetchHistory(agentKey)`，调用 `GET /api/history`
  并把结果映射成 `ChatMessage`。
- `lib/features/chat/bot_chat_controller.dart`：移除 `_historyStore` 和所有 `_persist()` 调用；
  `loadFor` 改为从后端 `fetchHistory` 拉历史（best-effort：离线/无历史时静默留空，且
  在飞行期间不覆盖用户已输入/已发送的消息）；`clearHistory` 不再清本地存储。
- `lib/features/chat/bot_chat_screen.dart`：新增 `_scrollToBottom({animated})`，
  `initState` 里用非动画方式直接跳到底部——重开即停在最新消息。
- `lib/app.dart`：`loadFor` 调用去掉 `await`（拉历史不阻塞启动）。
- `README.md` / `README.zh-CN.md`：在 features 列表里加了一条说明此行为。

**验证状态**（2026-05-22）：
- ✅ `flutter analyze`（全项目）No issues found。
- ✅ `flutter build apk --release` 成功（68.1MB）。
- ✅ `adb install -r app-release.apk` Success（设备 `R38M20NXWPL`）。
- ✅ **真机测试通过**（用户确认）。
- 注：后端代码（`history.js` / `server.js`）不参与 APK 构建，部署时需重启后端进程才生效。

---

## 2026-05-22 — 已废弃：语音输入 + 清理遗留代码 (`7b16331`)

**历史记录**：当时接入过语音输入；该功能已在 2026-05-23 后续记录中移除。该提交同时
删掉早期“app 内直接调用 LLM / 管理 agent provider”的整套遗留实现。

- 大规模删除遗留代码：`lib/core/llm/*`（claude/gemini/openai 客户端）、
  `lib/core/models/agent.dart`、`llm_provider.dart`、`lib/core/storage/agents_store.dart`、
  `api_keys_store.dart`、整个 `lib/features/agents/*`（agent 编辑/列表界面）。
- 同步更新 `README*` 与 `ROADMAP*`。

## 2026-05-21 — 文档完善 + setup.sh (`b59561e`, `f698259`)

- 新增 `setup.sh`：交互式一键搭后端（含 cloudflared quick tunnel + PM2 进程
  `agentdeck-tunnel`）。
- `README.md` 增加 Quick Start；`README.zh-CN.md` 补齐对应的中文 Quick Start，保持两份文档同步。

## 2026-05-21 — 原生额度通知 + 修复 Antigravity 重复回复 (`3f29985`)

- 原生 OS 额度通知（Android/iOS/macOS）：新增
  `lib/core/notifications/notification_service.dart`，`main.dart` 初始化；
  后端 `ENABLE_QUOTA_WATCH`、`QUOTA_POLL_MS`（见 `server/lib/quota-watch.js`、`server/.env.example`）。
  Android 侧改了 `build.gradle.kts`、`AndroidManifest.xml`（通知权限）。
- 修复 Antigravity (`agy`) 回复重复的问题（`server/lib/agents.js`、`bot_chat_controller.dart`）。
- 重写 `server/scripts/create-credential.js`（加密凭证二维码生成，Options A/B/C）。

## 2026-05-21 — 额度弹窗 + 工作目录管理 (`a1c52a7`)

- 额度查询改成**弹窗**展示（不写进聊天记录）：显示 Claude Code / Codex 的 5 小时与
  本周剩余额度及刷新时间，Antigravity 标注暂未开放。后端 `server/lib/usage.js`。
- 工作目录管理：`lib/features/workdir/work_directory_screen.dart`、
  `server/lib/workdir.js`，相关接口 `/api/workdir`、`/api/workdir/check`、`/api/workdir/reset`。
- 文档整理：删除早期的 `HANDOFF.md`、`IMPROVEMENTS.md`、`TODO.md`，
  新增 `ROADMAP.md` / `ROADMAP.zh-CN.md` 和 `README.zh-CN.md`。

## 2026-05-21 — 初始版本 (`5aa0aea`)

AgentDeck 初始提交：Flutter 客户端 + Node.js 后端骨架。

---

## 后端接口总览（当前）

`/api/health`、`/api/status`、`/api/agents`、`/api/auth/status`、`/api/usage`、
`/api/workdir`、`/api/workdir/check`、`POST /api/workdir`、`/api/workdir/reset`、
`/api/chat`、`/api/chat/cancel`、`/api/history`、`/api/session/clear`、`/api/events`。
