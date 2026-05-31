# macOS Backend

The macOS backend reuses the shared Node server in `server/` and installs
LaunchAgent services under `~/Library/LaunchAgents`.

## Requirements

- macOS with Node.js 18 or newer.
- Claude Code / Codex / Antigravity CLIs installed and logged in on the Mac.
- Tailscale for the recommended networking mode (install on the Mac and each
  client device, signed into the same account):

```bash
brew install node
brew install tailscale && sudo tailscale up   # or the Mac App Store app
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
- in Tailscale mode, detects this machine's stable `100.x` Tailscale IP;
- runs `npm run credential` so the terminal shows and saves the encrypted
  credential QR pointing at that address.

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
```

## Notes

LaunchAgent services do not inherit your interactive shell PATH. The generated
plist sets a PATH that includes common Homebrew and user-bin locations so
`claude`, `codex`, and `agy` can be found when launched by macOS.

The backend binds to `0.0.0.0` so the Tailscale interface can reach it; the
tailnet keeps it private. For direct mode (public IP/domain), put a reverse
proxy with HTTPS in front of it before exposing it beyond a trusted network.
