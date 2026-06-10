# 后端代码审查记录 (Backend Code Integrity)

> 本文档记录对 `server/` 后端（约 6800 行 Node.js）的一次完整人工审查发现的问题，
> 涵盖**性能卡顿、安全风险、可优化点、复用性/简洁性**四类。
> 每条标注了文件位置、问题描述与建议的修复方向，供后续逐条解决。
>
> 审查日期：2026-06-09 · 修复日期：2026-06-10（commit `2a1cf31` 起） ·
> 状态图例：⬜ 待处理 / 🔧 进行中 / ✅ 已解决

---

## 优先级总览

| 优先级 | 事项 | 编号 | 状态 |
|---|---|---|---|
| 🔴 高 | usage.js HTTP 请求无超时，会永久卡死 | P-5 | ✅ |
| 🔴 高 | 文件系统全盘读写：token 泄露即宿主机失陷/RCE | S-1 | ✅ |
| 🟠 中 | 每个请求两次同步读 tokens.json | P-1 | ✅ |
| 🟠 中 | chat-sessions.js 读路径也会同步落盘 | P-2 | ✅ |
| 🟠 中 | 超长 prompt 作为 argv 传递会导致 spawn 失败 | P-8 | ✅ |
| 🟠 中 | agent-sessions 读-改-写竞态丢失更新 | P-3 | ✅ |
| 🟡 低 | 其余性能/安全/复用项 | 见下 | ✅ |

**修复实现概览**：新增 `server/lib/json-store.js`（带缓存的原子 JSON 存储，统一解决
P-1/P-2/P-3/O-2/R-3）、`server/lib/subscription-store.js`（push/fcm 共用存储与分发，R-2）、
`server/lib/notify.js`（双通道一次调用，O-1）。新增环境变量：`PROMPT_MAX_BYTES`、
`CORS_ALLOW_ORIGIN`、`RELAY_FS_ROOTS`、`USAGE_HTTP_TIMEOUT_MS`（见 `.env.example`）。
`FILE_UPLOAD_LIMIT` 已随流式上传移除（上限统一由 `UPLOAD_MAX_BYTES` 控制）。

---

## 一、性能 / 卡顿（阻塞事件循环或产生延迟）

> Node 单线程：热路径上的同步 I/O 会让所有客户端（SSE、聊天流、文件下载）一起停顿。

### P-1 ✅ 每个 API 请求同步读两次 `tokens.json`（最高频）
- **位置**：`server/server.js:170` (`requireAuth`) → `server/lib/tokens.js:9-16`
- **问题**：`requireAuth` 每次请求都调用 `hasConfiguredToken()` 和 `isTokenAllowed()`，
  两者各执行一次 `fs.readFileSync` + `JSON.parse`。token 几乎不变。
- **修复方向**：将 token 记录缓存在内存中，仅在本模块写入（`writeTokenRecords`）时失效。
  所有写入都经过同一函数，失效时机可控。

### P-2 ✅ `chat-sessions.js` 连「读」都会同步写盘
- **位置**：`server/lib/chat-sessions.js:103-120` (`resolveChatSession`)，
  同类问题见 `listChatSessions`、`touchChatSession`
- **问题**：`resolveChatSession` 在纯查询路径上无条件 `saveAll()`，
  即每次 `GET /api/history` 都同步重写整个 `chat-sessions.json`。
  一个 agent turn 内 `touchChatSession` 会被多次调用。
- **修复方向**：读操作不落盘；写操作走内存缓存 + 防抖刷盘（参考 history.js 的做法）。

### P-3 ✅ `agents.js` 会话存储每次 get/set 全量读写 + 竞态
- **位置**：`server/lib/agents.js:80-96` (`getSession`/`setSession`/`clearSession`)
- **问题**：每次都 `loadSessions()` + `saveSessions()` 同步全量读写。
  且是**读-改-写竞态**：两个不同 scope 的并发 turn 同时结束时，后写覆盖先写，丢失 session id 更新。
- **修复方向**：内存缓存整张表，写入时合并而非整体覆盖；或加序列化写队列。

### P-4 ✅ 流式输出期间周期性全量序列化历史
- **位置**：`server/lib/history.js:33-37` (`saveAll`)
- **问题**：内存缓存 + 防抖（300ms 空闲 / 2s 上限）设计良好，但 `saveAll` 是
  `writeFileSync` 整个历史文件（所有 scope × 最多 200 条）。流式回复期间每 ≤2 秒
  同步写一次全量 JSON，历史文件大了会出现周期性卡顿。
- **修复方向**：改用 `fs.promises.writeFile`（保留 tmp+rename 原子性），或按 scope 拆文件。

### P-5 🔴 ✅ `usage.js` 的 HTTP 请求没有超时（会无限卡）
- **位置**：`server/lib/usage.js:193` (`httpJson`)、`server/lib/usage.js:301` (`httpHeadersOnly`)
- **问题**：两个 `https.request` 都未设 timeout。网络挂起时：
  - `/api/usage` 永远不返回；
  - `scheduleRefresh` 的单飞 promise（usage.js:132-145）永不 settle，后台刷新从此卡死；
  - `quota-watch` 的 `setInterval(check)` 会堆积重叠检查。
- **修复方向**：给请求加 `timeout` 选项 + `req.on('timeout', () => req.destroy())`。
- **备注**：这是唯一会让端点**永久卡死**的问题，建议最先修。

### P-6 ✅ 上传整个文件缓冲进内存
- **位置**：`server/server.js:123-128` (`express.raw`，上限 ~101MB)
- **问题**：几个并发大文件上传即可顶爆内存。
- **修复方向**：改为流式写入临时文件再 rename。

### P-7 ✅ `spawnStream` 无上限累积 stdout
- **位置**：`server/lib/agents.js:187` (`stdout += text`)
- **问题**：claude 用 `--verbose stream-json` 跑长任务时 stdout 可累积到几十上百 MB。
  对 claude 而言 `finalize` 不用 stdout（只用 stderr 和 finalText）。
- **修复方向**：有 `onLine` 时不累积 stdout，或设上限只保留尾部。

### P-8 🟠 ✅ 超长 prompt 作为 argv 传递会导致 spawn 失败
- **位置**：`server/lib/agents.js:284`（及 codex/agy 同类），入口 `server.js:157` 允许 16MB body
- **问题**：prompt 作为 argv 传给 CLI。Linux 单参数上限约 128KB（MAX_ARG_STRLEN），
  用户粘贴大文件内容会触发 E2BIG。
- **修复方向**：改用 stdin 传 prompt，或在入口限制 prompt 长度并返回明确错误。

### P-9 ✅ 次要性能项
- `listAbsoluteDirectory` 对每个目录项同步 `lstatSync`（`filesystem.js:88-104`），
  上万文件的目录会卡顿。
- `model-discovery` 同步扫描 ~250MB 二进制（有缓存 + 启动预热缓解，
  但 CLI 更新后首次请求仍会卡几秒）。
- `sendWindowsDirectoryZip` 中的 `mkdtempSync`（`server.js:247`）。

---

## 二、安全风险

### S-1 🔴 ✅ 认证后即拥有宿主机用户的完整文件系统读写（最大结构性风险）
- **位置**：`server/lib/filesystem.js:202` (`prepareDownloadAbsolute`)、
  `server/lib/filesystem.js:250` (`resolveAbsoluteUploadTarget`)
- **问题**：绝对路径模式是有意的「全盘可达」设计，但意味着泄露的设备 token 可以：
  - 读 `~/.ssh/`、`~/.claude/.credentials.json`、`server/.env`、`server/tokens.json`；
  - 写覆盖 `tokens.json` 给自己签发新 token，或覆盖 `server.js` 等待重启 → RCE。
  - `docs/production-hardening.md` 未提及这一层。
- **修复方向**：
  - 提供可选的 `RELAY_FS_ROOTS` 允许列表（默认 home 目录，可配置）；
  - 将 `server/` 自身敏感文件（tokens.json、.env、credentials/）加入下载/上传黑名单。

### S-2 ✅ token 比较不是常数时间
- **位置**：`server/lib/tokens.js:34-38` (`isTokenAllowed`，用 `===`)
- **问题**：256 位随机 token 被计时攻击攻破概率极低，但属于应规避的模式。
- **修复方向**：用 `crypto.timingSafeEqual` 比较 SHA-256 摘要，成本近乎为零。

### S-3 ✅ CORS 全开 `Access-Control-Allow-Origin: *`
- **位置**：`server/server.js:159`
- **问题**：任意网站 JS 都能向后端发请求。靠 Bearer token 兜底（浏览器不自动带），
  非直接漏洞，但配合 S-1 攻击面偏大。
- **修复方向**：用配置项限定允许的 origin。

### S-4 ✅ 上传符号链接竞态（TOCTOU）
- **位置**：`server/server.js:999-1010`
- **问题**：先 `existsSync` + `realpathSync` 检查目标在 root 内，再 `writeFile`，
  检查与写入间有时间窗；且**绝对路径上传模式根本不走此检查**
  （`resolveAbsoluteUploadTarget` 的 realRoot 就是目标目录自身）。
- **修复方向**：用 `O_NOFOLLOW` 打开，或写入后再校验 realpath；与 S-1 一并处理。

### S-5 ✅ 凭证 KDF 迭代偏低
- **位置**：`server/lib/credential-file.js:8` (PBKDF2-SHA256 120000 次)
- **问题**：OWASP 2023 对 PBKDF2-SHA256 建议 600000 次；密码下限仅 6 位
  （`create-credential.js:117`）进一步降低离线爆破成本。
- **修复方向**：提高迭代数，或改用 scrypt/argon2。

### S-6 ✅ `agy` 的 prompt 位置可能导致参数注入
- **位置**：`server/lib/agents.js:490-496`（prompt 在 `--add-dir` 等 flag 之前）
- **问题**：prompt 以 `-` 开头或含被 agy 解析为 flag 的内容时可能参数注入
  （非 shell 注入，spawn 未开 shell，风险较低）。claude/codex 都把 prompt 放最后。
- **修复方向**：统一把 prompt 放在 `--` 之后或参数末尾。

### S-7 ✅ `chat-history.json` 存储未脱敏的原始内容
- **位置**：`server/lib/history.js`（`redactSensitiveText` 仅用于导出/搜索）
- **问题**：落盘的历史是原始明文，可能含密钥/token。文件虽为 0o600，
  但任何能读该文件的进程都能拿到明文。
- **修复方向**：属可接受的设计权衡，记录在案；如需提升可在落盘前脱敏。

---

## 三、可优化点（性能/正确性）

### O-1 ✅ 配额/任务双路推送重复
- **位置**：`server/server.js` 中 `processDueQuotaSchedules`、`notifyTaskCompletion`、
  quota_reset 三处都是 `push.notify(...)` + `fcm.notify(...)` 成对出现且 catch 逻辑相同。
- **修复方向**：抽一个 `notifyAll({...})` 同时分发两个通道。

### O-2 ✅ 部分 JSON 写入非原子
- **位置**：`server/lib/agents.js:77` (`saveSessions`)、`chat-sessions.js:21`、`agent-settings.js:25`
- **问题**：history/usage/push 用了 tmp+rename 原子写，但 agent-sessions、chat-sessions、
  agent-settings 没用。进程写一半被 kill 会留下损坏 JSON（load 有 try/catch 兜底成空对象，
  但会丢失全部映射）。
- **修复方向**：统一走原子写。

### O-3 ✅ `hasPresence` / `workdirBusy` 是 O(n) 线性扫描
- **位置**：`server/server.js:355` (`hasPresence`)、`server/server.js:476` (`workdirBusy`)
- **问题**：连接数/scope 数大时每次广播和每个请求都扫一遍。
- **修复方向**：维护 `workdir -> count` 计数 Map。

---

## 四、复用性 / 简洁性

> 整体抽象不错：`runAgentTurn` 统一了聊天与定时任务，`agent-options` 是单一事实源，
> `resolveAgentScope` 收敛了 agent+workdir+session 解析。以下可进一步提升。

### R-1 ✅ 三个 agent runner 高度重复
- **位置**：`server/lib/agents.js:260-570` (`runClaude`/`runCodex`/`runAgy`)
- **问题**：共享同样结构——读 prior session、resuming 判断、`buildArgs`、`spawnStream`、
  `.then` 里处理 `__retry`/`__authError`。`__retry` 重试逻辑（claude/codex 完全一致）
  和末尾 `.then` handler 可抽公共包装。
- **修复方向**：抽 `withSessionRetry(runner)` 包装器统一重试/鉴权错误处理。

### R-2 ✅ `push.js` 与 `fcm.js` 存储层完全可复用
- **位置**：`server/lib/push.js`、`server/lib/fcm.js`
- **问题**：`loadXxx`/`saveXxx`/`normalizeRecord`/`normalizeCategories`/`categoryAllowed`/
  upsert/remove 整套逻辑两文件各写一遍，`notify` 函数体也几乎逐行雷同。
- **修复方向**：抽 `subscription-store` 工厂，传入文件名与 endpoint 提取函数。

### R-3 ✅ JSON 文件存储模式重复了 8 处
- **位置**：tokens、agent-sessions、chat-sessions、agent-settings、cards、push、fcm、quota-schedules
- **问题**：每个都自写 `loadAll`/`saveAll`（try-catch + 0o600）。
- **修复方向**：抽 `jsonStore(filePath, { atomic, defaultValue })` 帮手，统一原子写 + 内存缓存，
  一并解决 P-1/P-2/O-2。

### R-4 ✅ `server.js` 1662 行偏大
- **位置**：`server/server.js`
- **修复方向**：路由按域拆分（fs、chat、sessions、quota、push）为 Express Router 模块，
  入口只做装配。
- **实现**（commit `2f8f420`，由 codex worker 完成、已验收）：拆出 `server/routes/`
  下 6 个模块（meta/push/fs/chat/sessions/quota），每个导出 `createXxxRouter(ctx)`
  工厂，共享状态与帮手经 `routeContext` 注入；server.js 降至 ~900 行（配置、中间件、
  共享状态、定时任务 runner、静态服务、启动块）。验收核对：40 条 API 路由与拆分前
  完全一致，`node --check` 全过，测试 14/14 通过。
