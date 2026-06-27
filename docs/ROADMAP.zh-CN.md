# 路线图

[English roadmap](ROADMAP.md) | [中文 README](../README.zh-CN.md)

## 已实现

- 仅通过二维码导入凭证，密码由用户自己设置。
- 每台设备独立 token，可在 `server/tokens.json` 中创建、吊销、记录最近使用设备，并删除已吊销的 token。
- 每个 `workdir + agent` 下支持多个命名持久会话，各自保留聊天历史和可续接 CLI 上下文。
- Claude Code 和 Codex 的 assistant 文本 SSE 流式显示；Web 端对长回复期间的高频 UI 更新做节流。
- 长任务取消。
- 同一 `workdir + agent + session` 会话内的并发消息自动排队。
- 主题、语言和全局字体大小切换。
- 当前主流程默认英文，可切换中文。
- 抽屉清理、首页导航页、机器状态、“开始使用”教程、关于弹窗和首次连接时的后端部署指南。
- 只读额度弹窗显示 Claude Code、Codex 和 Antigravity 的 5 小时、本周剩余额度。
- 额度刷新提醒改为系统原生通知（Android / iOS / macOS / Windows），发送到通知栏而非聊天消息框。
- 额度刷新定时消息独立成左栏**“定时消息”**页:可按工作区为下一次 Claude Code 或 Codex 5 小时额度刷新预设一条消息,后端检测到刷新后自动发送;同一工作区多设备同步,并提供“清除已排程”取消。
- 通过 `GET /api/diagnostics` 和机器状态弹窗提供更完整的后端诊断。
- 面向稳定公网部署的自有域名 / 直连模式生产加固指南。
- app 内管理工作路径；每台设备本地保存当前路径，并在每次请求时发给后端。
- app/Web 端支持限定在当前 workdir 内的文件浏览、上传与下载。
- 未生成 token 时，受保护 API 不再以未鉴权状态运行。
- `backends/` 下区分平台后端安装入口：Linux 使用 PM2，macOS 使用 LaunchAgent，Windows 使用 PowerShell/计划任务。
- 跨设备事件按 workdir 和当前 session scope 镜像。
- 左侧抽屉支持为每个 CLI agent 新建、切换、删除会话。
- 单 agent 会话支持后台任务跟踪；长任务离开当前聊天后仍可继续，并在抽屉中显示运行状态。
- Windows 原生 Flutter 桌面前端，已验证 release 构建，与移动端、Web 端共享客户端代码。
- 离线远程推送（Web 端用 Web Push，Android 用 Firebase Cloud Messaging）：额度刷新
  提醒和定时消息发送结果，按设备可开关订阅，即使 app 进程被系统完全杀掉、SSE 断开也能收到。
- 一批带专门测试落地的后端热路径重构：抽出共享的 `runAgentTurn` 模块
  （`server/lib/agent-turn.js`），供 `/api/chat` 和定时消息 runner 共用；给
  `history.js` 加内存缓存 + 防抖写盘，取代每个流式 delta 都整文件重读重写的做法；
  以及用单个 `resolveAgentScope(req, res)` 替换各请求 handler 里重复的 agent scope 前导代码。
- 完整的后端完整性审查与修复（23 项审查发现全部解决）：带缓存的原子 JSON 存储、
  常数时间 token 校验、文件 API 敏感路径拒绝清单 + 可选 `RELAY_FS_ROOTS` 允许列表、
  流式上传、外发请求超时、更强的凭证 KDF，以及把 `server.js` 按域拆分到
  `server/routes/` 路由模块。
- 完整的前端完整性审查与修复（16 项审查发现全部解决）：凭证解密和大体积历史解码
  移出 UI isolate、共享 SSE 事件流加空闲超时让断死连接能自动重连、流式 delta 改
  缓冲拼接、凭证/设备/工作目录存储加缓存、文件列表惰性构建、native 上传改流式，
  以及所有后端调用方共用一个 API transport。
- Experimental CLI agent（OpenCode、Hermes），含 binary 检测、session resume、
  模型/effort/权限配置树、动态列表（只有安装后才在 UI 显示）。
- BTW (by the way) 旁路提问：只读 `/api/btw` 端点，不干扰主任务——Claude fork
  其原生 CLI session，Codex 与 Antigravity 则克隆主对话另起只读旁路 session。
- 蜂群（多智能体群聊，界面名 **Swarm** / 蜂群）：命名的蜂群成员共享一份记录，
  按 `@` 召唤发言；同一条人类消息里被召唤的多个成员会基于同一份记录快照并行运行，
  同时每个成员自己的蜂群 session 仍按自身队列串行。每个蜂群固定自己的工作目录
  （work tree）和各成员的模型/思考深度/权限，按工作区列出（同一工作区可有多个
  蜂群，各自选定 work tree），并作为常显子项出现在左侧抽屉。详见
  `docs/handbook.md`。
- Antigravity 模型选择：`agy` 通过 `--model` 暴露模型目录，蜂群与单聊均可固定到
  具体的 Gemini / Claude / GPT-OSS 模型。
- 多段消息：每条 assistant 回复独立时间戳，前端可折叠展示；后端发送 `segment`
  SSE 事件，消息元数据中记录 `{ ts, text }` 段。
- Agent 图标：每个 agent 独立 PNG 资源（含亮/暗主题），替换原图标字体。
- 支持 BTW 的 agent 统一使用紧凑的 `BTW` 文字图标，不再使用灯泡隐喻。

## 规划

### 跨平台客户端与后端

目标形态：

1. Android / iOS 手机连接 Linux / macOS / Windows 后端。
2. Windows / macOS / Linux 桌面前端全部使用 Flutter 原生桌面应用，桌面端与移动端、Web 端共享 Flutter 客户端代码。
3. 各后端平台提供服务安装、正式 Cloudflare Tunnel、Cloudflare Quick Tunnel、直连公网主机模式、CLI agent 检测与诊断。

复用边界：

- HTTP/SSE API、二维码凭证格式、token 吊销、会话语义保持平台无关。
- Flutter 的聊天、凭证、设置、机器管理、后端 client 逻辑保持共用。
- Node 的鉴权、会话、并发控制、额度报告、agent 调度保持共用。
- 平台差异放到 adapter 层：默认工作路径、进程启动/取消、服务管理、隧道地址发现、shell 行为、额度来源。

### 后续提升

- iOS 接入 Apple 推送通知服务(APNs)，把现有的离线推送(Web Push + FCM)扩展到
  被完全杀掉的 iOS app。
- Antigravity 额度已通过本地 `agy` language-server RPC
  (`RetrieveUserQuotaSummary`) 接入,该接口返回按模型组划分的 5 小时/周额度
  bucket 和精确 remaining fraction。当前限制:来源依赖正在运行的 Antigravity
  CLI 本地实例,不是官方公开 REST API;`/api/usage` 有缓存时可展示缓存,没有缓存
  且本地 RPC 不可达时会明确提示先启动一次 `agy`。
