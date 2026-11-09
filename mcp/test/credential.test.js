'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

// The backend's own encoder, so the MCP stays compatible with real credentials.
const { encryptCredential } = require('../../server/lib/credential-file');
const { decryptCredential } = require('../lib/credential');

const machine = { id: 'm1', name: 'pc', baseUrl: 'https://relay.example.com/', token: 'secret-token' };

test('decrypts a backend credential from inline JSON or a file path', () => {
  const envelope = JSON.stringify(encryptCredential(machine, 'hunter22'));
  assert.deepEqual(decryptCredential(envelope, 'hunter22'), {
    id: 'm1',
    name: 'pc',
    baseUrl: 'https://relay.example.com',
    token: 'secret-token',
  });
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'relay-mcp-')), 'pc.relay.json');
  fs.writeFileSync(file, envelope);
  assert.equal(decryptCredential(file, 'hunter22').token, 'secret-token');
});

test('rejects a wrong or missing password', () => {
  const envelope = JSON.stringify(encryptCredential(machine, 'hunter22'));
  assert.throws(() => decryptCredential(envelope, 'wrong-pass'), /decryption failed/);
  assert.throws(() => decryptCredential(envelope, ''), /RELAY_CREDENTIAL_PASSPHRASE/);
  assert.throws(() => decryptCredential('', 'hunter22'), /RELAY_CREDENTIAL is not set/);
});

test('refuses a Cloudflare Quick Tunnel address', () => {
  const quick = { ...machine, baseUrl: 'https://some-words-here.trycloudflare.com' };
  const envelope = JSON.stringify(encryptCredential(quick, 'hunter22'));
  assert.throws(() => decryptCredential(envelope, 'hunter22'), /Quick Tunnel/);
});
