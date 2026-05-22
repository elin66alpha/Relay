# AgentDeck 提升路线图

记录已确认提升项及其设计方向。范围 = `AgentDeck` Flutter 客户端 + `server/` 机器端后端。
现状基线见 `README.md` / `HANDOFF.md`。

> 状态图例：✅ 已实现 ｜ 🟡 搁置

---

## 1. 真正的流式回答 ✅

**现状**：`/api/events` 的 SSE 只推「进度行」（`agent_progress`）；最终答案是一次 `POST /api/chat`
阻塞最多 65 分钟后整段返回，再由 app 在本地逐字「假装打字」（`bot_chat_controller.dart` 的
`enqueue`/`tick`）。用户在答案出来前只能看到进度，体验是「卡很久 → 突然整段冒出」。

**目标**：答案 token 也通过 SSE 增量下发，做到真·增量显示。

**方向**：
- 后端：在 `runClaude`/`runCodex` 的 `onLine` 里，把 `assistant` 文本增量作为新事件
  （如 `agent_delta`，带 `requestId` + `text`）通过 `sendEvent` 推出；`/api/chat` 仍返回最终
  整段作为兜底/落库。agy 不流式（CLI 只在结束时输出），保持「处理中」占位即可。
- 前端：`_handleEvent` 增加 `agent_delta` 分支，按 `requestId` 把增量追加到对应 assistant 气泡，
  替换当前「POST 返回后本地逐字」的伪流式；POST 的最终结果用于对账/纠偏与持久化。

**注意**：增量与最终整段可能因网络重连错位，需以 `requestId` 对齐，并在 finalize 时以 POST
的权威结果为准覆盖。

---

## 2. 长任务「停止」按钮 ✅

**现状**：单任务超时上限 60 分钟（`AGENT_TIMEOUT_MS`），期间无法中途取消。

**目标**：用户可随时终止当前在跑的 agent 任务。

**方向**：
- 后端：维护 `requestId → child process` 映射；新增 `POST /api/chat/cancel`（body `{ requestId }`），
  对对应子进程 `SIGKILL`，并推一个 `agent_cancelled` 事件。
- 前端：`isThinking` 时输入区的发送键切换为「停止」键，调用 cancel；收到 `agent_cancelled`
  后把该气泡标记为「已取消」。

---

## 3. 多设备会话隔离 ✅

**现状**：持久会话只按 `agentKey` 区分（`server/agent-sessions.json`）。若两台手机连同一台机器，
会共用并互相串掉同一条 Claude/Codex 会话。

**目标**：不同设备各自独立的会话上下文。

**方向**：
- 会话 key 从 `agentKey` 扩展为 `deviceId:agentKey`。
- `deviceId` 来源：app 首次启动生成一个稳定随机 ID，存进 `flutter_secure_storage`，
  每次请求带 `X-Device-Id` 头；后端用它拼 key。
- `/api/session/clear` 同步带 `deviceId`，只清本设备的会话。
- 兼容：缺 `X-Device-Id` 时回退到旧的纯 `agentKey` key（老客户端不破）。

> 注意与第 4 项的关系：并发限制应按 `deviceId:agentKey` 粒度，避免两台设备互相误伤。

---

## 4. 从根本上禁止同一 agent 并发 ✅（决策：拒绝，而非排队）

**现状**：同一 agent 两条消息并发时，会同时 `resume` 同一会话 ID，第二条通常失败
（会话被锁/串上下文）。

**决策**：不做排队，**直接禁止**——同一 agent（结合第 3 项后为同一 `deviceId:agentKey`）
同时只允许一个在跑的请求，第二个请求立即被拒。

**方向**：
- 后端：维护「在跑集合」（key = `deviceId:agentKey`）。`/api/chat` 进入时若该 key 已在跑，
  直接返回 `409 Conflict`（如 `{ error: 'agent busy', code: 'AGENT_BUSY' }`），不启动子进程；
  请求结束（成功/失败/取消/超时）时从集合移除。
- 前端：`isThinking` 期间已禁用发送键（单 app 实例内已天然串行）；额外处理 `409`：
  收到 `AGENT_BUSY` 时提示「该 agent 正在处理上一条消息」，并把刚发出的用户消息标记为可重试，
  不计入历史污染。

---

## 5. 凭证口令文件风险 ✅

**现状**：旧流程曾在 `server/credentials/` 下保存 `*.passphrase.txt` 明文口令，与加密凭证放在一起 —— 等于加密失效（拿到机器即拿到口令）。

**目标**：口令永不落盘。

**方向**：
- 删除现有 `*.passphrase.txt`。
- `create-credential.js` 已支持交互输入或 `AGENTDECK_CREDENTIAL_PASSPHRASE` 环境变量，
  不需要也不应写出口令文件；确认无任何流程会生成它。
- `server/.gitignore` 已忽略 `credentials/*.passphrase.txt`（防止误提交），但根治是不生成。

---

## 6. 令牌轮换 / 吊销 ✅

**现状**：`APP_TOKEN` 是单一静态 token。手机丢失只能全量重生成 + 所有设备重导凭证。

**目标**：支持多 token 与吊销，丢一台设备只吊销那一个。

**方向**：
- 后端：`.env` 的单 `APP_TOKEN` 升级为「token 列表」（如 `server/tokens.json`，每条带
  `id / token / label / createdAt / revoked`）。`requireAuth` 校验 token 是否在有效集合内。
- 配套：`create-credential.js` 每生成一份凭证二维码就追加一个新 token（按设备/标签区分），
  而不是覆盖唯一 token；提供吊销命令（标记 `revoked` 即时失效）。
- 当前实现：已移除 `.env` 单 `APP_TOKEN` 兼容项，所有有效凭证都必须来自 `server/tokens.json`，便于逐个吊销。

---

## 7. 隧道 URL 漂移 ✅

**现状**：cloudflared quick tunnel 重启换 URL → 凭证二维码里的 `baseUrl` 失效，要重生成并重新扫码导入。

**目标**：URL 稳定，换机/重启不需要重发凭证。

**方向**（任选其一，优先前者）：
- 固定域名的 cloudflared **命名隧道**（URL 永久固定），凭证二维码一次生成即可长期有效。
- 或 ngrok 付费固定子域名。
- 退一步：加一个轻量「发现端点」——app 用一个稳定的小服务查当前真实隧道 URL 再连，
  但这又引入一个需维护的稳定服务，不如直接上命名隧道。

---

## 8. 杂项小改 🟡（搁置）

暂不做，记录备查：
- `GET /api/usage/:agent` 实际忽略 `:agent` 始终返回两段额度，app 可直接调 `/api/usage` 更干净。
- 「测试当前机器」只能测激活的那台，不能测列表里点中的具体 tile。
- 错误文案中英文混用，可统一为中文。

---

## 9. 抽屉栏精简与设置页升级 ✅

**现状**：
1. 抽屉栏包含了一个“机器”标题以及其下所有导入机器的列表（包括名称和公网IP），这与顶部最新的“状态显示机器卡片（ActiveMachineStatusTile）”以及“管理凭证”界面的功能严重重合，信息显示冗余且可能暴露敏感 IP。
2. 设置界面缺乏“关于”入口，无法查看App的基础版本和版权信息。

**目标**：
1. 移除抽屉栏冗余的“机器”小节，保持界面极致清爽。
2. 在设置页面增加一个“关于（About）”入口，提供版本和基础信息。

**方向**：
- **移除“机器”段落**：在 `lib/features/cli_agents/cli_agents_drawer.dart` 中，彻底移除 `context.l10n.machines` 文本以及 credentials 的 `for` 循环列表渲染。只保留顶部的 `ActiveMachineStatusTile` 和“管理凭证”按钮。
- **新增“关于”入口**：在 `lib/features/settings/app_settings_screen.dart` 的 `ListView` 底部，追加一个 `ListTile` 展示“关于”信息，包含应用名称、当前版本号 `0.1.0+1` 及版权信息。

---

## 10. AgentDeck 跨平台路线 🟡（规划）

**目标形态**：AgentDeck 成为跨设备、跨桌面系统的私有 agent 控制台。

**阶段路线**：
1. Android / iOS 手机连接 Linux / macOS / Windows 后端。
2. Linux / macOS / Windows 桌面客户端连接 Linux / macOS / Windows 后端。
3. 各后端平台提供服务化安装、隧道配置、CLI agent 检测与诊断。

**复用边界**：
- Flutter 客户端的聊天、凭证、机器管理、设置、后端 API client 应保持共用。
- HTTP/SSE 协议、二维码凭证、token 轮换/吊销机制应保持平台无关。
- Node 后端的鉴权、会话管理、并发控制、agent 调度主流程应保持共用。
- 平台差异只落在 adapter 层：默认工作目录、shell/spawn 参数、进程取消、service manager、cloudflared/ngrok 路径与日志、quota 查询来源。

**判断**：方向可行，且不是重写型路线。关键是从现在开始避免把 Linux 路径、PM2、bash、进程信号、扫码入口等平台细节写进核心业务逻辑。
