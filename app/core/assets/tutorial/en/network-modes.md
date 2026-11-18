---
title: Network modes and HTTPS
category: Backend setup
order: 230
summary: Direct, named Cloudflare Tunnel, Quick Tunnel and Tailscale compared, plus reverse proxy requirements.
keywords: network, tunnel, cloudflare, trycloudflare, https, reverse proxy, caddy, nginx, direct, tailscale
---

Setup asks how the app reaches the backend. That address (`PUBLIC_BASE_URL`) is stored in the credential, so when it changes you must generate and import a new credential.

## The four modes

**1. Direct**

The backend listens on `0.0.0.0` and you enter an address the client device can reach: a LAN IP, a Tailscale address, or your own reverse-proxied domain.

- Other devices cannot use `localhost` to reach your host.
- Put HTTPS and a firewall in front before exposing it to the internet. A public `http://` address triggers a warning from the backend but is not blocked.

**2. Named Cloudflare Tunnel**

Uses your domain on Cloudflare: a stable address with HTTPS, while the backend listens only on `127.0.0.1`. Best for long-term use.

**3. Cloudflare Quick Tunnel**

No domain needed, the fastest start. But the `trycloudflare.com` address can change when `cloudflared` restarts. When it does, find the new address in the service logs and run from the repository root:

```bash
npm --prefix server run credential -- --url https://NEW-URL
```

then import the new credential in the app. [Relay MCP](relay-mcp.md) refuses Quick Tunnel addresses.

**4. Tailscale**

Relay listens only on the detected tailnet IPv4. Native apps can use `http://<tailscale-ip>:<port>` over WireGuard. Relay Web needs HTTPS to store credentials. To use it, configure a reverse proxy with a trusted certificate on port 443 forwarding to that tailnet IP and backend port, then enter its hostname during setup. Open that HTTPS address and import the generated credential. Leaving the hostname blank configures native apps only and disables Web.

- Install Tailscale on each phone or computer that uses Relay and sign in to the same tailnet.
- If Tailscale is missing or not signed in, setup says so and shows the menu again so you can install it or pick another mode.

## The Web client and HTTPS

The backend can serve the Web client at the same address (chosen during setup, on by default). A Web client opened over HTTPS must also connect to an HTTPS backend, or the browser blocks it.

## Behind your own reverse proxy

If Caddy, Nginx or similar sits in front of the backend:

- Keep `HOST=127.0.0.1` on the backend.
- Do not buffer the SSE responses of `/api/events`, `/api/chat` and `/api/group/chat`.
- Forward the WebSocket `Upgrade` / `Connection` headers for `/api/terminal/connect` and `/api/browser/connect`, and do not log their `ticket` query value.
- Keep timeouts above `AGENT_TIMEOUT_MS` (60 minutes by default).
- Pass the real client address in `X-Forwarded-For` (trusted only from a local proxy).
- Match the default limits of 100 MB per upload and 300 MB per download.

## Rate limits

Ordinary API requests are limited to 600 per minute per IP; failed tokens to 15 per minute per IP. Chat streams and file transfers do not count towards the ordinary limit but still need a token.
