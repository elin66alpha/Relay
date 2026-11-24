'use strict';

// Claude Code keeps its OAuth login in ~/.claude/.credentials.json on Linux and
// Windows, but in the macOS login Keychain (service "Claude Code-credentials")
// on darwin. The usage/keepalive paths need the actual token, and the refresh
// token rotates, so a refreshed token must be written back to the same place
// it came from — otherwise the CLI is left holding a dead refresh token.

const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const KEYCHAIN_SERVICE = 'Claude Code-credentials';
const DEFAULT_CREDS_PATH = path.join(os.homedir(), '.claude', '.credentials.json');
// Reading with -w can block on the macOS "allow security to access" prompt the
// first time; give the user a moment to click it, but never hang forever.
const KEYCHAIN_SECRET_TIMEOUT_MS = 30_000;
const KEYCHAIN_ATTR_TIMEOUT_MS = 3_000;

function parseKeychainAttributes(text) {
  const out = { account: null, modifiedMs: 0 };
  const acct = /"acct"<blob>="((?:[^"\\]|\\.)*)"/.exec(text);
  if (acct) out.account = acct[1];
  const mdat = /"mdat"<timedate>=(?:0x[0-9A-Fa-f]+\s+)?"(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z/.exec(text);
  if (mdat) {
    const [, y, mo, d, h, mi, s] = mdat.map(Number);
    out.modifiedMs = Date.UTC(y, mo - 1, d, h, mi, s);
  }
  return out;
}

function decodeKeychainSecret(raw) {
  const text = String(raw || '').trim();
  if (!text) return '';
  // `security -w` prints non-printable secrets as hex; Claude Code's JSON is
  // printable, but accept both forms.
  if (!text.startsWith('{') && /^[0-9a-fA-F]+$/.test(text) && text.length % 2 === 0) {
    return Buffer.from(text, 'hex').toString('utf8');
  }
  return text;
}

function quoteForSecurityShell(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

const macKeychain = {
  // Attribute-only lookup: never touches the secret, never prompts.
  find() {
    const r = spawnSync('security', ['find-generic-password', '-s', KEYCHAIN_SERVICE], {
      encoding: 'utf8',
      timeout: KEYCHAIN_ATTR_TIMEOUT_MS,
    });
    if (r.status !== 0) return null;
    return parseKeychainAttributes(`${r.stdout || ''}\n${r.stderr || ''}`);
  },
  readSecret() {
    const out = execFileSync(
      'security',
      ['find-generic-password', '-s', KEYCHAIN_SERVICE, '-w'],
      { encoding: 'utf8', timeout: KEYCHAIN_SECRET_TIMEOUT_MS, stdio: ['ignore', 'pipe', 'pipe'] },
    );
    return decodeKeychainSecret(out);
  },
  // Goes through `security -i` on stdin with a hex payload so the token never
  // appears in argv (visible to `ps`).
  writeSecret(account, secret) {
    const hex = Buffer.from(secret, 'utf8').toString('hex');
    const cmd = `add-generic-password -U -a ${quoteForSecurityShell(account)} -s ${quoteForSecurityShell(KEYCHAIN_SERVICE)} -X "${hex}"\n`;
    const r = spawnSync('security', ['-i'], {
      input: cmd,
      encoding: 'utf8',
      timeout: KEYCHAIN_SECRET_TIMEOUT_MS,
    });
    if (r.status !== 0 || /error/i.test(r.stderr || '')) {
      throw new Error(`Failed to write Claude credentials to Keychain: ${(r.stderr || '').trim() || `exit ${r.status}`}`);
    }
  },
  has() {
    return spawnSync('security', ['find-generic-password', '-s', KEYCHAIN_SERVICE], {
      stdio: 'ignore',
      timeout: KEYCHAIN_ATTR_TIMEOUT_MS,
    }).status === 0;
  },
};

function createClaudeCredentialStore(options = {}) {
  const filePath = options.filePath || DEFAULT_CREDS_PATH;
  const platform = options.platform || process.platform;
  const fsModule = options.fs || fs;
  const keychain = options.keychain || macKeychain;

  function fileExists() {
    try {
      fsModule.statSync(filePath);
      return true;
    } catch (_err) {
      return false;
    }
  }

  function useKeychain() {
    return platform === 'darwin' && !fileExists();
  }

  // Returns { creds, source: 'file' | 'keychain', account }.
  function read() {
    if (!useKeychain()) {
      return {
        creds: JSON.parse(fsModule.readFileSync(filePath, 'utf-8')),
        source: 'file',
        account: null,
      };
    }
    const attrs = keychain.find();
    if (!attrs) {
      throw new Error('Claude credentials were not found (no credentials file and no Keychain entry). Run claude login.');
    }
    let secret;
    try {
      secret = keychain.readSecret();
    } catch (err) {
      throw new Error(
        'Could not read Claude credentials from the macOS Keychain. ' +
        'Allow "security" access on the Mac (click "Always Allow"); a backend ' +
        `started without a GUI session cannot show that prompt. (${err.message})`,
        { cause: err },
      );
    }
    return { creds: JSON.parse(secret), source: 'keychain', account: attrs.account };
  }

  function readCreds() {
    return read().creds;
  }

  // Writes back to wherever the credentials were read from.
  function write(creds, from) {
    const origin = from || read();
    const json = JSON.stringify(creds);
    if (origin.source === 'keychain') {
      const account = origin.account || os.userInfo().username;
      keychain.writeSecret(account, json);
      return;
    }
    const tmp = `${filePath}.tmp`;
    fsModule.writeFileSync(tmp, json, { mode: 0o600 });
    fsModule.renameSync(tmp, filePath);
  }

  function mtimeMs() {
    if (!useKeychain()) {
      try {
        return fsModule.statSync(filePath).mtimeMs;
      } catch (_err) {
        return 0;
      }
    }
    try {
      const attrs = keychain.find();
      return (attrs && attrs.modifiedMs) || 0;
    } catch (_err) {
      return 0;
    }
  }

  return { read, readCreds, write, mtimeMs, filePath };
}

module.exports = {
  KEYCHAIN_SERVICE,
  createClaudeCredentialStore,
  decodeKeychainSecret,
  macKeychain,
  parseKeychainAttributes,
};
