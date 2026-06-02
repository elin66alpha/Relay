# Production Hardening For Custom Domains And Direct Mode

[中文](production-hardening.zh-CN.md) | [README](../README.md)

AgentDeck can run behind a named Cloudflare Tunnel, or directly on a public
host. Quick Tunnel is useful for trials, but production use should have a
stable URL, a small attack surface, and a clear recovery path.

## Recommended Shape

- Use HTTPS only. For a named Cloudflare Tunnel, terminate HTTPS at Cloudflare.
  For direct public-host mode, put Nginx, Caddy, or another reverse proxy in
  front of AgentDeck and terminate TLS there.
- Keep AgentDeck bound to localhost unless the reverse proxy or tunnel runs on
  another host. Prefer `HOST=127.0.0.1` with a proxy/tunnel to `HOST=0.0.0.0`.
- Set `PUBLIC_BASE_URL` to the exact stable URL users import into the app, for
  example `https://agent.example.com`. Regenerate credentials after changing it.
- Keep `server/.env`, `server/tokens.json`, and `server/credentials/` out of
  source control. They contain deployment identity, access tokens, and encrypted
  credential exports.
- Generate a separate credential for each user/device. Revoke old device tokens
  from `server/tokens.json` instead of sharing one long-lived token.

## Reverse Proxy Checklist

- Forward `GET`, `POST`, and long-lived `GET /api/events` requests.
- Disable buffering for `/api/events` and streaming `/api/chat` responses.
- Keep request timeouts longer than the agent timeout. The default agent timeout
  is 60 minutes.
- Set upload and download caps deliberately. Defaults are 100 MB upload and
  300 MB download; tune `FILE_UPLOAD_LIMIT`, `DOWNLOAD_MAX_BYTES`, and
  `DOWNLOAD_MAX_BYTES` only if the proxy and network can handle them.
- Avoid broad CORS exposure at the proxy layer. AgentDeck's device token is the
  real API gate, but a narrow proxy configuration reduces accidental exposure.

## Direct Public Host Checklist

- Put the Node process behind a service manager such as PM2, systemd,
  LaunchAgent, or a Windows Scheduled Task.
- Run as a non-root user that owns only the intended work directories.
- Restrict inbound firewall rules to the reverse proxy port, normally 443.
- Keep the backend port private. If you must expose it directly, require HTTPS
  at the edge and rotate credentials after any test exposure.
- Use `GET /api/diagnostics` from an authenticated app session to verify public
  URL, token state, CLI availability, active requests, storage files, and workdir
  access after deployment changes.

## Operational Checks

- After changing `PUBLIC_BASE_URL`, run the credential script again and import
  the new credential in the app.
- After rotating or revoking tokens, verify old devices fail and current devices
  still pass `GET /api/health`.
- Watch server logs during long agent turns and file transfers; stream endpoints
  should stay connected instead of completing early.
- Keep a rollback path for tunnel/proxy changes: the local backend should still
  answer on `http://127.0.0.1:<PORT>` from the backend host.

