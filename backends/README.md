# AgentDeck Backend Targets

AgentDeck keeps the backend core in `server/` and puts operating-system setup
in this directory.

- `linux/`: Linux backend entrypoint. It wraps the existing PM2-based setup.
- `macos/`: macOS backend setup using LaunchAgent services for the Node backend.
- `windows/`: Windows backend setup using PowerShell background processes and
  a per-user Scheduled Task.

Setup scripts offer three network modes: no tunnel/direct public address,
named Cloudflare Tunnel for a stable hostname in your Cloudflare zone, or
Cloudflare Quick Tunnel for a temporary `https://*.trycloudflare.com` trial URL.

The Flutter app talks to the same HTTP/SSE API on every backend platform. The
platform folders only handle installation, service management, logs, PATH, and
tunnel URL lookup.
