# macOS 后端

macOS 后端复用 `server/` 里的 Node 后端核心，并把服务安装为
`~/Library/LaunchAgents` 下的 LaunchAgent。

## 前置要求

- macOS，Node.js 18 或更新版本。
- Mac 上已经安装并登录 Claude Code / Codex / Antigravity CLI。
- 默认 quick tunnel 网络模式需要 `cloudflared`：

```bash
brew install node
brew install cloudflared
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
- 隧道模式下创建 cloudflared LaunchAgent：`dev.agentdeck.tunnel`；
- 从隧道日志读取最新的 `trycloudflare.com` 地址；
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
~/Library/Logs/AgentDeck/tunnel.out.log
~/Library/Logs/AgentDeck/tunnel.err.log
```

## 说明

LaunchAgent 不会继承你在终端里的 shell PATH。生成的 plist 会写入常见 Homebrew 和用户
bin 路径，确保 macOS 启动服务时能找到 `claude`、`codex` 和 `agy`。

Quick Tunnel 模式下后端绑定到 `127.0.0.1`，cloudflared 从本机访问后端。若用直连模式
（公网 IP/域名），后端绑定到 `0.0.0.0`，对外暴露前请在前面放 HTTPS 反向代理。
