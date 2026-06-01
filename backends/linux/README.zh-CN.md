# Linux 后端

Linux 目前继续使用仓库根目录已有的 PM2 安装流程。

```bash
cd /path/to/AgentDeck
backends/linux/setup.sh
```

这个入口会调用 `./setup.sh`。脚本提供三种网络模式：

1. 不用隧穿 / 公网直连；
2. 稳定域名的正式 Cloudflare Tunnel；
3. 临时 `trycloudflare.com` 地址的 Cloudflare Quick Tunnel 快速试用。

两种 Cloudflare 隧穿模式都需要先安装 `cloudflared`。

常用命令：

```bash
pm2 list
pm2 logs agentdeck-server
pm2 restart agentdeck-server
pm2 logs agentdeck-tunnel
```
