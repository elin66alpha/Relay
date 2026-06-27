# Security

Relay is a self-hosted control surface for local CLI coding agents. This page
explains what the project protects, what it does not protect, and how to deploy
it responsibly.

## Trust Boundary

Relay has two main parts:

- **Client app:** Flutter app for mobile, Web, and desktop.
- **Backend:** Node service running on a machine you control. It starts local
  CLI agents and can read/write files that the backend OS user can access.

There is no Relay-hosted cloud control plane. The app connects only to the
backend URL inside the credential you import.

## Credential and Token Model

Credential setup creates an encrypted QR/JSON envelope containing:

- machine id and display name
- backend base URL
- one bearer token for that device

The envelope uses:

- PBKDF2-HMAC-SHA256, currently 600,000 iterations
- AES-256-GCM
- random salt and nonce

The credential password is entered interactively and is not written to disk. The
backend stores bearer tokens in `server/tokens.json`; the client stores imported
machine credentials in platform secure storage through `flutter_secure_storage`.

Recommended practice:

- Generate one credential per device.
- Revoke and delete old tokens instead of sharing a long-lived token.
- Treat QR images and credential JSON files like passwords.
- Regenerate credentials after changing `PUBLIC_BASE_URL`.

## Backend API Protections

Protected `/api/*` routes require `Authorization: Bearer <token>`.

Implemented backend protections include:

- no-token-configured mode that rejects protected APIs before a credential is
  generated
- constant-time token digest comparison for active tokens
- per-IP API rate limiting
- stricter rate limiting for failed auth attempts
- token last-use metadata for device id/name tracking
- token revocation and deletion
- startup warning for routable plaintext `http://` public URLs

## File API Protections

The file browser intentionally works against the backend filesystem so users can
work with real project files. To prevent a leaked token from escalating into
credential theft, Relay always denies access to sensitive paths, including:

- `server/tokens.json`
- `server/.env`
- `server/credentials/`
- push subscription and FCM token stores
- `~/.ssh`
- known Claude Code and Codex auth files

Directory downloads also refuse trees that contain those sensitive paths.

For stricter deployments, set `RELAY_FS_ROOTS` to a comma-separated list of
absolute directories that the file API may access. This limits browse, upload,
and download operations; it does not limit what the CLI agents themselves can do
as the backend OS user.

## Deployment Requirements

For any backend reachable outside the local machine:

- Put TLS in front of the backend. Prefer a named Cloudflare Tunnel or a reverse
  proxy such as Caddy or Nginx.
- Keep the Node backend bound to `HOST=127.0.0.1` when a tunnel or local reverse
  proxy is in front.
- Set `PUBLIC_BASE_URL` to the exact HTTPS URL users will import.
- Run the backend as a non-root user.
- Give that OS user access only to the workdirs Relay should control.
- Keep `server/.env`, `server/tokens.json`, `server/credentials/`, and push
  service credentials out of git and out of release archives.

See the production checklist in
[docs/handbook.md](docs/handbook.md#production-deployment).

## What Relay Does Not Do

Relay is not a sandbox:

- CLI agents run as real processes under the backend OS user.
- Agent permission modes are delegated to the underlying CLI tools.
- A token with access to the backend can operate the Relay API until revoked.
- Relay cannot protect a machine that is already compromised.
- Relay cannot make plaintext public HTTP safe; use HTTPS for public access.

## Reporting Security Issues

Please do not open a public issue for a suspected vulnerability that exposes
tokens, credentials, private files, or remote execution paths. Contact the
maintainer privately first, then open a public advisory or issue after a fix is
available.
