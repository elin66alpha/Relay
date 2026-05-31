# Linux Backend

Linux currently uses the existing PM2-based setup from the repository root.

```bash
cd /path/to/AgentDeck
backends/linux/setup.sh
```

This wrapper calls `./setup.sh`, which offers Cloudflare Quick Tunnel mode
(default; `cloudflared tunnel --url http://localhost:8787`) or direct mode for
a VPS/public host. Install `cloudflared` for tunnel mode.

Useful commands:

```bash
pm2 list
pm2 logs agentdeck-server
pm2 restart agentdeck-server
pm2 logs agentdeck-tunnel
```
