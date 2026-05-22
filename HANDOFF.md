# Handoff

## Current Behavior

- The Flutter app no longer has a built-in backend URL.
- On first launch, the app shows the credential import screen.
- A user must scan the credential QR code (printed by `npm run credential` on the machine) and enter its password before the app can use Claude Code, Codex, or Antigravity on a machine. There is no file-import path anymore.
- Multiple machine credentials can be stored on one phone and switched from the drawer.
- Chat history is scoped by machine id and CLI agent key.
- Each CLI agent keeps one persistent conversation per app device on the machine (Claude `--resume`, Codex `exec resume`, agy `--conversation`); ids live in `server/agent-sessions.json` under `deviceId:agentKey`. "清空当前对话" clears local history and calls `POST /api/session/clear` to reset that device's agent session.
- Claude/Codex assistant text is streamed over SSE as `agent_delta`; the final `POST /api/chat` body is still treated as the authoritative answer.
- The input send button becomes a stop button while a turn is running and calls `POST /api/chat/cancel`.

## Credential Flow

1. Make sure `agentdeck-tunnel` (cloudflared) is running.
2. Generate the credential QR (no arguments needed):

```bash
cd /path/to/AgentDeck/server
npm run credential
```

The script auto-detects the public tunnel URL from the `agentdeck-tunnel` PM2 logs, prompts for a password (min 6 chars), and prints a QR code in the terminal plus saves a PNG to `server/credentials/<name>.agentdeck.png`. For non-interactive use, set `AGENTDECK_CREDENTIAL_PASSPHRASE` (and optionally `--url` to override detection).

3. In the app, tap "扫描二维码", scan the printed/PNG QR, and enter the password.

The QR encodes the credential envelope (public tunnel URL + a per-device token from `server/tokens.json`), encrypted with PBKDF2-SHA256 + AES-256-GCM. No plaintext credential file is produced. The server enforces `Authorization: Bearer <token>` for all `/api/*` routes, accepting only non-revoked tokens in `server/tokens.json` (the `.env` `APP_TOKEN` fallback was removed — every live token is revocable).

Token operations:

```bash
npm run credential -- --list-tokens
npm run credential -- --revoke <token-id>
```

## Tunnel Notes

- `server/ecosystem.config.js` includes a cloudflared quick tunnel process.
- Quick tunnel URLs are suitable for testing but may change after restart.
- For reliable remote phone use, configure a stable cloudflared/ngrok domain and generate the credential QR with that stable URL.
- Keep `HOST=127.0.0.1` unless there is a specific reason to expose the backend directly on the LAN; the tunnel process can still reach the local backend.

## Files To Know

- `lib/core/credentials/credential_file_codec.dart` decrypts the QR credential envelope payload.
- `lib/core/storage/machine_credentials_store.dart` stores imported machine credentials in secure storage.
- `lib/features/machines/` contains the import/manage UI and controller.
- `lib/core/backend/backend_client.dart` reads the active machine credential for every HTTP/SSE request.
- `server/scripts/create-credential.js` auto-detects the tunnel URL, prompts for a >=6-char password, appends a per-device token to `server/tokens.json` (revoking older tokens with the same label), persists `.env` values, and outputs the credential as a QR (terminal + PNG, no plaintext credential file).
- `server/lib/credential-file.js` owns the Node-side credential encryption format.
- `server/lib/tokens.js` is the token store: append (`createToken`), check (`isTokenAllowed`), and revoke (`revokeToken`/`revokeTokensByLabel`) against `server/tokens.json` (gitignored).
- `server/lib/agents.js` is the agent registry + streaming runner + per-`deviceId:agentKey` persistent sessions; `server/agent-sessions.json` holds the session ids (gitignored, do not hand-edit).
- `server/lib/workdir.js` only resolves/creates the shared workdir; all CLI execution is in `agents.js`.

## Operational Checklist

1. Ensure `server/tokens.json` has an active (non-revoked) token for each imported device credential.
2. Ensure `PUBLIC_BASE_URL` is the same public URL used in the latest credential QR.
3. Restart `agentdeck-server` after changing `.env` values that the running process reads at startup, or after editing any `server/lib/*.js` (require cache).
4. If the tunnel URL changes, regenerate the credential QR and scan it again in the app.
5. After Flutter changes, run:

```bash
flutter pub get
flutter test
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```
