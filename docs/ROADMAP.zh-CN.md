# 路线图

[English roadmap](ROADMAP.md) | [中文 README](README.zh-CN.md)

## 已实现

- 仅通过二维码导入凭证，密码由用户自己设置。
- 每台设备独立 token，可在 `server/tokens.json` 中吊销。
- 每个 `workdir + agent` 下支持多个命名持久会话，各自保留聊天历史和可续接 CLI 上下文。
- Claude Code 和 Codex 的 assistant 文本 SSE 流式显示；Web 端对长回复期间的高频 UI 更新做节流。
- 长任务取消。
- 同一 `workdir + agent + session` 会话内的并发消息自动排队。
- 主题和语言切换。
- 当前主流程默认英文，可切换中文。
- 抽屉清理、机器状态、关于弹窗。
- 只读额度弹窗显示 Claude Code 和 Codex 的 5 小时、本周剩余额度。
- 额度刷新提醒改为手机系统原生通知，发送到通知栏而非聊天消息框。
- 额度刷新定时消息独立成左栏**“定时消息”**页:可按工作区为下一次 Claude Code 或 Codex 5 小时额度刷新预设一条消息,后端检测到刷新后自动发送;同一工作区多设备同步,并提供“清除已排程”取消。
- 通过 `GET /api/diagnostics` 和机器状态弹窗提供更完整的后端诊断。
- 面向稳定公网部署的自有域名 / 直连模式生产加固指南。
- app 内管理工作路径；每台设备本地保存当前路径，并在每次请求时发给后端。
- app/Web 端支持限定在当前 workdir 内的文件浏览、上传与下载。
- 未生成 token 时，受保护 API 不再以未鉴权状态运行。
- `backends/` 下区分平台后端安装入口：Linux 使用 PM2，macOS 使用 LaunchAgent，Windows 使用 PowerShell/计划任务。
- 跨设备事件按 workdir 和当前 session scope 镜像。
- 左侧抽屉支持为每个 CLI agent 新建、切换、删除会话。

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

- 离线远程推送(FCM / APNs):额度刷新提醒和定时消息发送结果,在 app 被系统完全
  杀掉时也能收到。目前这些依赖 app 进程存活且 SSE 在线;真正的离线推送需要接入
  Firebase Cloud Messaging(Android)/ Apple 推送通知服务(iOS),并在后端加一个
  推送发送端。
- 等 Antigravity 有可靠 API 或 CLI 来源后补充额度支持。**2026-06-04 已评估
  (agy 1.0.5):刻意暂不实现。** agy 基于 Gemini Code Assist
  (`cloudcode-pa.googleapis.com`),唯一的配额路径是未公开的内部 `v1internal`
  接口(如 `FetchQuotaStatus` / `GetUsageAndQuota` / `v1internal/credits`)。其
  配额是基于信用额度的多维模型(prompt / flow / flex / FCA 等多种 credits,分
  档位、可加购),没有能干净映射到现有"5 小时 / 周剩余"额度 UI 的单一数值,且需
  逆向 protobuf/gRPC schema、无稳定性保证。会话内的 `/credits` `/limits`
  `/usage` 斜杠命令只在交互式 TUI 里(不可脚本化)。待 Google 提供官方、可脚本化
  的配额来源再做;在此之前 `usage.js` 继续把 agy 报告为 `not_available_yet`。
