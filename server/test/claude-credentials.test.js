'use strict';

const assert = require('node:assert/strict');
const { after, test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  createClaudeCredentialStore,
  decodeKeychainSecret,
  parseKeychainAttributes,
} = require('../lib/claude-credentials');

const scratchDirs = [];
after(() => {
  for (const dir of scratchDirs) fs.rmSync(dir, { recursive: true, force: true });
});

function credsPath() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-claude-creds-'));
  scratchDirs.push(dir);
  return path.join(dir, '.credentials.json');
}

// A fake Keychain that records every call so tests can assert it was untouched.
function fakeKeychain(secret) {
  const calls = [];
  return {
    calls,
    writes: [],
    find() {
      calls.push('find');
      return secret ? { account: 'alice', modifiedMs: 1234 } : null;
    },
    readSecret() {
      calls.push('readSecret');
      return JSON.stringify(secret);
    },
    writeSecret(account, json) {
      calls.push('writeSecret');
      this.writes.push({ account, json });
    },
  };
}

const LOGIN = { claudeAiOauth: { accessToken: 'a1', refreshToken: 'r1' } };

test('on macOS without a credentials file the login is read from the Keychain', () => {
  const keychain = fakeKeychain(LOGIN);
  const store = createClaudeCredentialStore({ filePath: credsPath(), platform: 'darwin', keychain });
  const origin = store.read();
  assert.deepEqual(origin, { creds: LOGIN, source: 'keychain', account: 'alice' });
  assert.equal(store.mtimeMs(), 1234);
});

test('a refreshed macOS token is written back to the Keychain, not to a file', () => {
  const filePath = credsPath();
  const keychain = fakeKeychain(LOGIN);
  const store = createClaudeCredentialStore({ filePath, platform: 'darwin', keychain });
  const origin = store.read();
  const refreshed = { claudeAiOauth: { accessToken: 'a2', refreshToken: 'r2' } };
  store.write(refreshed, origin);
  assert.deepEqual(keychain.writes, [{ account: 'alice', json: JSON.stringify(refreshed) }]);
  assert.equal(fs.existsSync(filePath), false);
  assert.equal(fs.existsSync(`${filePath}.tmp`), false);
});

test('an existing credentials file is used on every platform and the Keychain is untouched', () => {
  for (const platform of ['darwin', 'linux']) {
    const filePath = credsPath();
    fs.writeFileSync(filePath, JSON.stringify(LOGIN));
    const keychain = fakeKeychain(LOGIN);
    const store = createClaudeCredentialStore({ filePath, platform, keychain });
    const origin = store.read();
    assert.equal(origin.source, 'file');
    assert.deepEqual(origin.creds, LOGIN);
    const refreshed = { claudeAiOauth: { accessToken: 'a2', refreshToken: 'r2' } };
    store.write(refreshed, origin);
    assert.deepEqual(JSON.parse(fs.readFileSync(filePath, 'utf8')), refreshed);
    assert.ok(store.mtimeMs() > 0);
    assert.deepEqual(keychain.calls, [], platform);
  }
});

test('on Linux without a credentials file the Keychain is never consulted', () => {
  const keychain = fakeKeychain(LOGIN);
  const store = createClaudeCredentialStore({ filePath: credsPath(), platform: 'linux', keychain });
  assert.throws(() => store.read(), { code: 'ENOENT' });
  assert.equal(store.mtimeMs(), 0);
  assert.deepEqual(keychain.calls, []);
});

test('parseKeychainAttributes reads the account and modification time', () => {
  const text = [
    'keychain: "/Users/alice/Library/Keychains/login.keychain-db"',
    'attributes:',
    '    "acct"<blob>="alice"',
    '    "mdat"<timedate>=0x32303236313131393132333435365A00  "20261119123456Z\\000"',
    '    "svce"<blob>="Claude Code-credentials"',
  ].join('\n');
  assert.deepEqual(parseKeychainAttributes(text), {
    account: 'alice',
    modifiedMs: Date.UTC(2026, 10, 19, 12, 34, 56),
  });
  assert.deepEqual(parseKeychainAttributes(''), { account: null, modifiedMs: 0 });
});

test('decodeKeychainSecret accepts plain JSON and hex output', () => {
  const json = JSON.stringify(LOGIN);
  assert.equal(decodeKeychainSecret(`${json}\n`), json);
  assert.equal(decodeKeychainSecret(Buffer.from(json, 'utf8').toString('hex')), json);
  assert.equal(decodeKeychainSecret(''), '');
});
