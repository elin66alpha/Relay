# macOS 后端

macOS 后端复用 `server/` 里的 Node 后端核心，并把服务安装为
`~/Library/LaunchAgents` 下的 LaunchAgent。

## 前置要求

- macOS，Node.js 18 或更新版本。
- Mac 上已经安装并登录 Claude Code / Codex / Antigravity CLI。
- 推荐网络模式需要 Tailscale（Mac 和每个客户端设备都装、登录同一账号）：

```bash
brew install node
brew install tailscale && sudo tailscale up   # 或 Mac App Store 版
```

## 安装

```bash
cd /path/to/AgentDeck
backends/macos/setup.sh
```

安装脚本会：

- 需要时从 `server/.env.example` 创建 `server/.env`；
- 安装后端 npm 依赖；
- 创建后端 LaunchAgent：`dev.agentdeck.backend`；
- Tailscale 模式下探测本机稳定的 MagicDNS 地址；
- 执行 `npm run credential`，在终端显示并保存指向该地址的加密凭证二维码。

## 服务命令

```bash
backends/macos/status.sh
backends/macos/start.sh
backends/macos/stop.sh
backends/macos/uninstall.sh
```

日志位置：

```text
~/Library/Logs/AgentDeck/backend.out.log
~/Library/Logs/AgentDeck/backend.err.log
```

## 说明

LaunchAgent 不会继承你在终端里的 shell PATH。生成的 plist 会写入常见 Homebrew 和用户
bin 路径，确保 macOS 启动服务时能找到 `claude`、`codex` 和 `agy`。

后端绑定到 `0.0.0.0`，让 Tailscale 接口能访问，tailnet 本身保证其私有性。若用直连模式
（公网 IP/域名），对外暴露前请在前面放 HTTPS 反向代理，不要裸露在不可信网络上。
