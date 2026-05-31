# Linux 后端

Linux 目前继续使用仓库根目录已有的 PM2 安装流程。

```bash
cd /path/to/AgentDeck
backends/linux/setup.sh
```

这个入口会调用 `./setup.sh`。脚本提供 Tailscale 模式（推荐：通过你自己的 tailnet 以稳定
`100.x` Tailscale IP 访问后端），也支持 VPS / 公网主机直连模式。先安装 Tailscale：
`curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`。

常用命令：

```bash
pm2 list
pm2 logs agentdeck-server
pm2 restart agentdeck-server
tailscale status        # 查看 tailnet / 本机地址
```
