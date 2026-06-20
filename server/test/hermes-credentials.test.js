'use strict';

const assert = require('node:assert/strict');
const { after, test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  updateModelProviderYaml,
  writeHermesApiKey,
} = require('../lib/hermes-credentials');

const scratchDirs = [];

function makeHome() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-hermes-auth-'));
  scratchDirs.push(dir);
  return dir;
}

after(() => {
  for (const dir of scratchDirs) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('updateModelProviderYaml inserts or replaces model.provider', () => {
  assert.equal(
    updateModelProviderYaml('', 'openrouter'),
    '\nmodel:\n  provider: openrouter',
  );
  assert.equal(
    updateModelProviderYaml('model:\n  provider: anthropic\nfoo: true', 'openrouter'),
    'model:\n  provider: openrouter\nfoo: true',
  );
});

test('writeHermesApiKey writes credential pool and model provider atomically', () => {
  const home = makeHome();
  const result = writeHermesApiKey({
    homeDir: home,
    provider: 'openrouter',
    apiKey: 'sk-test',
    label: 'Relay test',
    now: () => new Date('2026-06-20T12:00:00Z'),
    uuid: () => 'uuid-1',
  });

  const auth = JSON.parse(fs.readFileSync(result.authPath, 'utf8'));
  const entry = auth.credential_pool.openrouter[0];
  assert.equal(entry.id, 'relay-uuid-1');
  assert.equal(entry.source, 'manual:api_key');
  assert.equal(entry.auth_type, 'api_key');
  assert.equal(entry.label, 'Relay test');
  assert.equal(entry.access_token, 'sk-test');
  assert.equal(entry.created_at, '2026-06-20T12:00:00.000Z');

  const config = fs.readFileSync(result.configPath, 'utf8');
  assert.match(config, /model:\n  provider: openrouter/);
  assert.equal(fs.existsSync(`${result.authPath}.tmp`), false);
});

test('writeHermesApiKey rejects invalid provider and empty key', () => {
  const home = makeHome();
  assert.throws(
    () => writeHermesApiKey({ homeDir: home, provider: '../x', apiKey: 'k' }),
    /provider is invalid/,
  );
  assert.throws(
    () => writeHermesApiKey({ homeDir: home, provider: 'openrouter', apiKey: '' }),
    /apiKey is required/,
  );
});
