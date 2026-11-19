# Relay privacy policy

[中文](#relay-隐私政策)

Effective 2026-11-19. This policy covers the Relay apps (iOS, Android, macOS,
Windows, Linux and Web) and the Relay backend.

Relay is open-source software. The app connects to a Relay backend that you
run on your own computer. The Relay developer runs no Relay servers and
receives no data from the app or the backend.

## What the app does not do

- No account with the developer, no sign-in to any Relay service.
- No analytics, advertising, tracking or crash reporting.

## Data kept on your device

- Machine credentials (your backend's address and access token), in the
  system's secure storage (the Keychain on iOS and macOS).
- App settings, such as language and theme.

## Data sent to your own backend

Everything you do in the app (messages, files you choose to upload, terminal
input, browser control) goes only to the backends you added, over the
address you configured. Your backend stores chat history, sessions and
settings on your own computer.

The coding agents your backend runs (such as Claude Code or Codex) send your
prompts and files to their own providers under those providers' terms, as
they do when you run them directly.

## Services the app contacts

- **GitHub**: the app asks `api.github.com` for the latest Relay version, and
  Android and desktop apps download updates from `github.com`. GitHub sees
  your IP address, as with any visit to GitHub.
- **Push notifications**: the release apps contain no Firebase configuration
  and send no push token anywhere. If you build the app yourself with your own
  Firebase project, its token goes to your backend and to Google's Firebase
  Cloud Messaging.

## Services the backend contacts

- The providers of the agents you use (such as Anthropic, OpenAI and Cursor),
  with the logins already on your computer, to run the agents and to read your
  usage quota for the quota view.
- GitHub, to check for and download backend updates.
- Optional services only when you set them up: a Cloudflare or Tailscale
  tunnel, and Firebase Cloud Messaging with your own service account.

## Device permissions

- **Camera**: only to scan your backend's credential QR code. Images are not
  stored or sent.
- **Notifications**: local notifications about your own agents' work.

Demo mode uses no network at all.

## Children

Relay is a developer tool and is not directed at children.

## Changes and contact

Changes to this policy are recorded in this file's history. Questions:
open an issue at <https://github.com/elin66alpha/Relay/issues>.

---

# Relay 隐私政策

[English](#relay-privacy-policy)

生效日期：2026-11-19。本政策适用于 Relay 各端 App（iOS、Android、macOS、
Windows、Linux 和 Web）以及 Relay 后端。

Relay 是开源软件。App 连接的是你在自己电脑上运行的 Relay 后端。Relay
开发者不运营任何 Relay 服务器，也不会从 App 或后端收到任何数据。

## App 不做的事

- 不需要在开发者处注册账号，也不登录任何 Relay 服务。
- 没有统计分析、广告、追踪或崩溃上报。

## 保存在你设备上的数据

- 机器凭证（后端地址和访问令牌），保存在系统的安全存储里（iOS 和 macOS
  上是钥匙串）。
- App 设置，例如语言和主题。

## 发送到你自己后端的数据

你在 App 里的所有操作（消息、你选择上传的文件、终端输入、浏览器控制）只会
发送到你添加的后端，走你配置的地址。聊天记录、会话和设置由你的后端保存在
你自己的电脑上。

你的后端运行的编程 Agent（例如 Claude Code、Codex）会按照各自服务商的条款，
把你的提示词和文件发送给这些服务商，和你直接运行它们时一样。

## App 会访问的服务

- **GitHub**：App 会向 `api.github.com` 查询 Relay 的最新版本，Android 和
  桌面端会从 `github.com` 下载更新。和访问任何 GitHub 页面一样，GitHub 能看到
  你的 IP 地址。
- **推送通知**：发布版 App 不包含 Firebase 配置，不会把推送令牌发到任何地方。
  如果你用自己的 Firebase 项目自行编译 App，令牌会发送到你的后端和 Google 的
  Firebase Cloud Messaging。

## 后端会访问的服务

- 你所用 Agent 的服务商（例如 Anthropic、OpenAI、Cursor）：使用你电脑上已有的
  登录状态运行 Agent，并读取你的用量配额，用于配额页面。
- GitHub：检查和下载后端更新。
- 只有你自己配置后才会使用的服务：Cloudflare 或 Tailscale 隧道，以及使用你
  自己服务账号的 Firebase Cloud Messaging。

## 设备权限

- **相机**：只用于扫描后端凭证二维码，图像不会保存或发送。
- **通知**：关于你自己 Agent 工作进度的本地通知。

演示模式完全不使用网络。

## 儿童

Relay 是开发者工具，不面向儿童。

## 变更与联系

本政策的变更记录在这个文件的历史里。有问题请在
<https://github.com/elin66alpha/Relay/issues> 提 issue。
