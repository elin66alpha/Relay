# AgentDeck Backend Targets

AgentDeck keeps the backend core in `server/` and puts operating-system setup
in this directory.

- `linux/`: Linux backend entrypoint. It wraps the existing PM2-based setup.
- `macos/`: macOS backend setup using LaunchAgent services for the Node backend.

Networking uses Tailscale (a private mesh): the backend is reached over your
tailnet at a stable `100.x` Tailscale IP (MagicDNS also works when client DNS
supports it), never exposed to the public internet. A
direct mode is available for hosts that already have a public IP/domain.

The Flutter app talks to the same HTTP/SSE API on every backend platform. The
platform folders only handle installation, service management, logs, PATH, and
the Tailscale address lookup.
