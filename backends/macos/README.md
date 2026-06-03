# macOS Backend

The macOS backend reuses the shared Node server in `server/` and installs
LaunchAgent services under `~/Library/LaunchAgents`.

## Requirements

- macOS with Node.js 18 or newer.
- Claude Code / Codex / Antigravity CLIs installed and logged in on the Mac.
- `cloudflared` for Cloudflare Tunnel or Quick Tunnel mode:

```bash
brew install node
brew install cloudflared
```

## Setup

```bash
cd /path/to/Relay
backends/macos/setup.sh
```

The setup script:

- creates `server/.env` from `server/.env.example` when needed;
- installs backend npm dependencies;
- creates a LaunchAgent for the backend (`dev.relay.app.backend`);
- offers direct mode, named Cloudflare Tunnel mode, or Quick Tunnel mode;
- in either tunnel mode, creates a LaunchAgent for cloudflared (`dev.relay.app.tunnel`);
- for Quick Tunnel, reads the latest `trycloudflare.com` URL from the tunnel logs;
- runs `npm run credential` so the terminal shows and saves the encrypted
  credential QR pointing at the chosen public URL.

## Service Commands

```bash
backends/macos/status.sh
backends/macos/start.sh
backends/macos/stop.sh
backends/macos/uninstall.sh
```

Logs:

```text
~/Library/Logs/Relay/backend.out.log
~/Library/Logs/Relay/backend.err.log
~/Library/Logs/Relay/tunnel.out.log
~/Library/Logs/Relay/tunnel.err.log
```

## Notes

LaunchAgent services do not inherit your interactive shell PATH. The generated
plist sets a PATH that includes common Homebrew and user-bin locations so
`claude`, `codex`, and `agy` can be found when launched by macOS.

In Cloudflare Tunnel and Quick Tunnel modes the backend binds to `127.0.0.1`,
and cloudflared reaches it locally. For direct mode (public IP/domain), bind to
`0.0.0.0` and put a reverse proxy with HTTPS in front of it before exposing it
beyond a trusted network.
