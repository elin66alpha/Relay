# Linux Backend

Linux currently uses the existing PM2-based setup from the repository root.

```bash
cd /path/to/AgentDeck
backends/linux/setup.sh
```

This wrapper calls `./setup.sh`, which offers three network modes:

1. no tunnel / direct public address;
2. named Cloudflare Tunnel for a stable hostname in your Cloudflare zone;
3. Cloudflare Quick Tunnel for a temporary `trycloudflare.com` trial URL.

Install `cloudflared` for either Cloudflare tunnel mode.

Useful commands:

```bash
pm2 list
pm2 logs agentdeck-server
pm2 restart agentdeck-server
pm2 logs agentdeck-tunnel
```
