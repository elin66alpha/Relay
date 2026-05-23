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

## 2026-05-22 — 语音输入 + 清理遗留代码 (`7b16331`)

**意图**：接入语音输入，并删掉早期“app 内直接调用 LLM / 管理 agent provider”的整套
遗留实现——现在架构是“客户端只控制后端 CLI”，那些代码已无用。

- 语音输入：客户端录音上传，后端 `POST /api/stt` 走 OpenAI STT
  （`OPENAI_API_KEY`、`STT_MODEL=gpt-4o-mini-transcribe`、`STT_MAX_AUDIO_BYTES`）。
  涉及 `backend_client.dart`、`app_strings.dart`、`AndroidManifest.xml`、`ios/Runner/Info.plist`。
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

`/api/health`、`/api/status`、`/api/agents`、`/api/usage`、`/api/stt`、
`/api/workdir`、`/api/workdir/check`、`POST /api/workdir`、`/api/workdir/reset`、
`/api/chat`、`/api/chat/cancel`、`/api/history`（新增）、`/api/session/clear`、`/api/events`。
