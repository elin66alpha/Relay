# AgentDeck Backend Targets

AgentDeck keeps the backend core in `server/` and puts operating-system setup
in this directory.

- `linux/`: Linux backend entrypoint. It wraps the existing PM2-based setup.
- `macos/`: macOS backend setup using LaunchAgent services for the Node backend
  and, optionally, a Cloudflare quick tunnel.

The Flutter app talks to the same HTTP/SSE API on every backend platform. The
platform folders only handle installation, service management, logs, PATH, and
tunnel discovery.
