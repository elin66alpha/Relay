# macOS Backend

The macOS backend reuses the shared Node server in `server/` and installs
LaunchAgent services under `~/Library/LaunchAgents`.

## Requirements

- macOS with Node.js 18 or newer.
- Claude Code / Codex / Antigravity CLIs installed and logged in on the Mac.
- Optional tunnel mode requires `cloudflared`:

```bash
brew install node
brew install cloudflared
```

## Setup

```bash
cd /path/to/AgentDeck
backends/macos/setup.sh
```

The setup script:

- creates `server/.env` from `server/.env.example` when needed;
- installs backend npm dependencies;
- creates a LaunchAgent for the backend (`dev.agentdeck.backend`);
- optionally creates a LaunchAgent for a Cloudflare quick tunnel
  (`dev.agentdeck.tunnel`);
- detects the `trycloudflare.com` URL from macOS logs;
- runs `npm run credential -- --url <public-url>` so the terminal shows and
  saves the encrypted credential QR.

## Service Commands

```bash
backends/macos/status.sh
backends/macos/start.sh
backends/macos/stop.sh
backends/macos/uninstall.sh
```

Logs:

```text
~/Library/Logs/AgentDeck/backend.out.log
~/Library/Logs/AgentDeck/backend.err.log
~/Library/Logs/AgentDeck/tunnel.out.log
~/Library/Logs/AgentDeck/tunnel.err.log
```

## Notes

LaunchAgent services do not inherit your interactive shell PATH. The generated
plist sets a PATH that includes common Homebrew and user-bin locations so
`claude`, `codex`, `agy`, and `cloudflared` can be found when launched by macOS.

If you do not use tunnel mode, direct mode binds the backend to `0.0.0.0`; put a
reverse proxy with HTTPS in front of it before exposing it beyond a trusted LAN.
