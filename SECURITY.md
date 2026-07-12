# Security

Relay is a self-hosted control surface for CLI coding agents. It protects the
connection to its own API and limits what its file endpoints expose, but it is
not a sandbox for the agents it launches.

## Trust boundary

Relay has two parts:

- a Flutter client for mobile, Web, and desktop;
- a Node.js backend on a machine you control, running with that machine user's
  filesystem and process permissions.

There is no Relay-hosted account or control plane. The client connects only to
the backend URL in an imported credential. Prompts, files, agent output, and CLI
credentials stay between your devices, backend host, and the CLI providers you
already use.

## Credentials and device tokens

The credential generator creates a `relay.credentials.v1` QR/JSON envelope with
the machine id/name, backend URL, and one bearer token. The envelope uses
PBKDF2-HMAC-SHA256 with 600,000 iterations plus AES-256-GCM with a random salt
and nonce. Its passphrase is entered interactively and is not written to disk.

The backend stores bearer-token records and metadata in `server/tokens.json`.
That file is a secret and is written owner-only. Native
clients store imported credentials through platform secure storage. Web storage
inherits the security of the browser profile and origin; use a trusted device
and private profile for sensitive backends.

Recommended practice:

- generate a separate credential for every device;
- treat generated QR/JSON files as secrets even though they are encrypted;
- revoke and delete a token when a device is lost or retired;
- regenerate credentials after changing `PUBLIC_BASE_URL`;
- never commit `.env`, tokens, credential exports, push keys, history, sessions,
  agent settings, groups, or CLI login state.

## API protections

Every `/api/*` endpoint requires `Authorization: Bearer <token>`. Until at least
one token exists, protected routes fail with `TOKEN_NOT_CONFIGURED` rather than
running unauthenticated.

Implemented controls include:

- timing-safe comparison of hashed candidate and stored active-token values;
- device id/name and last-use metadata without exposing token values;
- token revocation and deletion;
- a 600-request/minute/IP limit for ordinary API requests;
- a separate 15-failed-auth-attempt/minute/IP limit;
- streaming chat/SSE/login and file-transfer routes excluded from the general
  request counter while still requiring authentication;
- `trust proxy` restricted to loopback so a direct client cannot spoof
  `X-Forwarded-For`;
- a startup warning when a routable public URL uses plaintext HTTP.

The in-app Claude/Codex/Agy login bridge starts the real CLI in a backend PTY.
It returns authorization URLs and status only, redacts URLs from diagnostic
output, and never returns stored OAuth tokens. The bridge currently depends on
GNU-compatible `script -qfec`; log in directly on hosts without it. OpenCode and
Hermes keys are managed outside Relay on the backend host.

## File API protections

By default, the file browser accepts absolute paths anywhere the backend user
can access. It always rejects these current sensitive locations:

- `server/tokens.json`, `server/.env`, and `server/credentials/`;
- `server/push-subscriptions.json` and `server/fcm-tokens.json`;
- `~/.ssh`;
- Claude Code's `.credentials.json` and Codex's `auth.json`.

The same policy applies to listing, upload, download, and atomic temp-file
variants. A directory download is also rejected when its tree would contain a
denied path.

This list is intentionally precise, not a promise to detect every secret. It
does not automatically cover arbitrary Agy, OpenCode, Hermes, provider, or
service-account files. Set `RELAY_FS_ROOTS` to a comma-separated allowlist of
absolute directories and run Relay as a restricted OS user. The allowlist
limits the file API only; it does not change what a launched CLI can access.

Uploads stream to a temporary file and default to 100 MB. Downloads default to
300 MB. Configure smaller proxy and Relay limits when the deployment does not
need those sizes.

## Production requirements

For a backend reachable beyond localhost:

- terminate TLS with a named Cloudflare Tunnel or a reverse proxy;
- bind Relay to `127.0.0.1` when the proxy/tunnel runs on the same host;
- set `PUBLIC_BASE_URL` to the exact HTTPS URL imported by clients;
- run the backend as a non-root user with access only to intended workdirs;
- configure `RELAY_FS_ROOTS`;
- keep the backend port private and forward only the TLS endpoint;
- disable proxy buffering for SSE/chat routes and set timeouts above the maximum
  agent turn duration;
- protect backend backups, because history and session files contain raw
  unredacted conversation content.

See the [production checklist](docs/handbook.md#production-deployment).

## What Relay does not do

- It does not sandbox Claude Code, Codex, Agy, OpenCode, or Hermes.
- It cannot stop an enabled fast mode or high-permission agent from consuming
  provider quota or changing files within its effective access.
- It cannot protect an already compromised backend host or browser profile.
- It cannot make a public plaintext HTTP connection safe.
- A valid device token remains powerful until it is revoked.

## Reporting issues

Do not publish a vulnerability that exposes tokens, credentials, private files,
or remote-execution paths before a fix is available. Contact the maintainer
privately, then coordinate a public advisory or issue after remediation.
