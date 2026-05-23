# Linux Backend

Linux currently uses the existing PM2-based setup from the repository root.

```bash
cd /path/to/AgentDeck
backends/linux/setup.sh
```

This wrapper calls `./setup.sh`, which can run in tunnel mode with
`cloudflared` or direct mode for a VPS/public host.

Useful commands:

```bash
pm2 list
pm2 logs agentdeck-server
pm2 logs agentdeck-tunnel
pm2 restart agentdeck-server
```
