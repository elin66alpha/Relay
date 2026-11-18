---
title: Import a credential and manage machines
category: Getting started
order: 130
summary: Connect by scanning, uploading the QR image or pasting JSON; add and switch machines.
keywords: credential, QR, scan, password, decrypt, machine, switch
---

A credential is the key that connects the app to a backend. It is an encrypted `relay.credentials.v1` file holding the backend address, the machine identity and one device token that can be revoked on its own. It is encrypted with PBKDF2-HMAC-SHA256 (600,000 iterations) and AES-256-GCM.

## Ways to import

Open **Settings** (under **Machine credentials** at the top, select **Add machine**), or use the first screen when no machine exists yet:

| Method | Platforms |
|---|---|
| Scan QR code | Android, iOS |
| Upload QR image | all |
| Paste credential (the QR payload or the text of `.relay.json`) | all |

Then enter **the password set when the credential was generated** and select **Decrypt**. The app tests the connection right away.

## Common messages

- **Credential decryption failed**: wrong password, or an incomplete QR.
- **Token rejected**: the credential's token was revoked, or replaced by a newer credential. Generate one again on the backend and import the newest.
- **Cannot resolve the host**: the address in the QR is no longer valid. With a Cloudflare Quick Tunnel it changes after a restart.
- **Connection refused**: the backend is not running, or not listening on the port in the QR.
- **Use plaintext HTTP?**: the address is `http://`. On a trusted LAN you can continue; across the internet use HTTPS.

## Several machines

Import one credential per backend. The machine card on Home and at the top of the drawer shows the connected one; under **Machine credentials** at the top of Settings, tap another to switch, use **Add machine** to import more, **Test current machine** to check the connection, or delete a machine you no longer use.

Switching machines also switches the workspace, session lists and Swarms to that machine's. A Swarm can also bring agents from several machines together; see [Members on other machines](swarm-remote-members.md).

## More credentials from the backend

From `server/` on the backend:

```bash
npm run credential
npm run credential -- --url https://relay.example.com
npm run credential -- --list-tokens
npm run credential -- --revoke <token-id>
```

The setup menu (`setup.sh` on Linux and macOS, `setup.cmd` on Windows) can also create, list and delete tokens or show a QR again (showing again asks for a new password, since the old one is never stored).

## Where credentials are kept

Native apps keep them in the platform's secure storage. The Web client keeps them in the browser's site storage, so its safety depends on the browser; use it only on trusted devices.

To review or revoke devices see [Device tokens](device-tokens.md).
