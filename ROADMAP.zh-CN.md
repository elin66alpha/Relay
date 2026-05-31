# 路线图

[English roadmap](ROADMAP.md) | [中文 README](README.zh-CN.md)

## 已实现

- 仅通过二维码导入凭证，密码由用户自己设置。
- 每台设备独立 token，可在 `server/tokens.json` 中吊销。
- 每台设备、每个 agent 独立持久会话。
- Claude Code 和 Codex 的 assistant 文本 SSE 流式显示。
- 长任务取消。
- 每个 `deviceId:agentKey` 同时只允许一个任务运行。
- 主题和语言切换。
- 当前主流程默认英文，可切换中文。
- 抽屉清理、机器状态、关于弹窗。
- 额度弹窗显示 Claude Code 和 Codex 的 5 小时、本周剩余额度。
- 额度刷新提醒改为手机系统原生通知，发送到通知栏而非聊天消息框。
- app 内管理工作路径，并持久写入后端 `.env`。
- app/Web 端支持限定在当前 workdir 内的文件浏览、上传与下载。
- 未生成 token 时，受保护 API 不再以未鉴权状态运行。
- `backends/` 下区分平台后端安装入口：Linux 使用 PM2，macOS 使用 LaunchAgent。
- 会话身份从 `deviceId + agent` 改为 `workdir + agent`：每台设备在本地各自持有当前工作路径（通过 `X-Workdir` 请求头发送），同一路径下的所有设备共享同一段对话、同一个可恢复的 CLI 会话与历史，彼此的消息以及 agent 的实时进度都会同步镜像。由于底层 CLI 会话不能并发，同一会话的并发消息会自动排队串行执行。跨设备事件按 workdir scope 广播，而不再只发给单台设备。

## 规划

### 跨平台客户端与后端

目标形态：

1. Android / iOS 手机连接 Linux / macOS / Windows 后端。
2. 用一套响应式 Web 前端作为所有平台的桌面客户端。Windows / macOS / Linux 桌面应用都是这套 Web 前端的套壳（webview 外壳），不再单独开发原生桌面 UI，三个平台共用同一份代码。
3. 各后端平台提供服务安装、Tailscale（私有 mesh）联网、CLI agent 检测与诊断。

复用边界：

- HTTP/SSE API、二维码凭证格式、token 吊销、会话语义保持平台无关。
- Flutter 的聊天、凭证、设置、机器管理、后端 client 逻辑保持共用。
- Node 的鉴权、会话、并发控制、额度报告、agent 调度保持共用。
- 平台差异放到 adapter 层：默认工作路径、进程启动/取消、服务管理、Tailscale 地址发现、shell 行为、额度来源。

### 后续提升

- **单工作路径多会话**: 支持在同一个工作路径下，为三个 AI agent 开启多个不同的 Session。切换到对应工作路径后，自动读取并恢复留存的 Session（包括名称和对话记忆）。在左侧栏 CLI 智能体位置增加一个“+”号按钮用于新建该 agent 的会话，并支持会话的删除功能。
- 可选 `tailscale serve`（仅 tailnet 的 HTTPS）与自有域名 / 直连模式加固指南。
- 桌面端通过二维码图片或粘贴 payload 导入凭证。
- 更完整的后端诊断。
- Windows 后端安装流程。
- 等 Antigravity 有可靠 API 或 CLI 来源后补充额度支持。
