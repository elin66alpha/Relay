---
title: Device tokens
category: Machine and tools
order: 720
summary: One token per device: review, revoke, delete, and what revoking does.
keywords: token, revoke, delete, device, security
---

Each credential holds one device token, and every backend API request needs it. Every device (and every [Relay MCP](relay-mcp.md) bot) should have its own, so each can be revoked on its own.

## Review

**Device tokens** in [Machine details](machine-details.md) lists each token: its label, who uses it, when it was created and last used. The current device is marked.

## Revoke and delete

1. **Revoke first**: the token stops working at once, and the terminal and browser it owns close.
2. **Then delete** the record.

Revoking the **current device's** token makes this device's next request return 401, and you need to import a valid credential again.

From the command line on the backend:

```bash
npm run credential -- --list-tokens
npm run credential -- --revoke <token-id>
```

A command-line revocation needs no restart; the terminal heartbeat picks it up.

## Note

- Generating another credential removes old export files but **does not revoke** tokens already issued.
- Do not share one token between devices.
