# Linux Backend

Linux currently uses the existing PM2-based setup from the repository root.

```bash
cd /path/to/AgentDeck
backends/linux/setup.sh
```

This wrapper calls `./setup.sh`, which offers Tailscale mode (recommended;
reach the backend over your private tailnet at a stable `100.x` Tailscale IP) or
direct mode for a VPS/public host. Install Tailscale first:
`curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`.

Useful commands:

```bash
pm2 list
pm2 logs agentdeck-server
pm2 restart agentdeck-server
tailscale status        # check the tailnet / this machine's address
```
