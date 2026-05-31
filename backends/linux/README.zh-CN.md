# Linux 后端

Linux 目前继续使用仓库根目录已有的 PM2 安装流程。

```bash
cd /path/to/AgentDeck
backends/linux/setup.sh
```

这个入口会调用 `./setup.sh`。脚本提供 Cloudflare Quick Tunnel 模式（默认：
`cloudflared tunnel --url http://localhost:8787`），也支持 VPS / 公网主机直连模式。隧道模式需要先安装 `cloudflared`。

常用命令：

```bash
pm2 list
pm2 logs agentdeck-server
pm2 restart agentdeck-server
pm2 logs agentdeck-tunnel
```
