'use strict';

// A CLI that is not signed in must not be re-queried and re-logged on every
// poll: the backoff holds even with no earlier successful reading, and an
// unchanged failure is logged once.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const home = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-usage-backoff-'));
process.env.HOME = home;
process.env.USERPROFILE = home;
process.env.RELAY_USAGE_CACHE_FILE = path.join(home, 'usage-cache.json');

const { macKeychain } = require('../lib/claude-credentials');
const { getClaudeUsage } = require('../lib/usage');
const { startClaudeQuotaKeepalive } = require('../lib/quota-keepalive');

test.after(() => fs.rmSync(home, { recursive: true, force: true }));

function captureWarnings(t) {
  const warnings = [];
  t.mock.method(console, 'warn', (line) => warnings.push(String(line)));
  return warnings;
}

test('Claude usage without credentials backs off and logs once', async (t) => {
  t.mock.method(macKeychain, 'find', () => null);
  const missingCredentials = process.platform === 'darwin'
    ? /no credentials file and no Keychain entry/
    : { code: 'ENOENT' };
  const warnings = captureWarnings(t);
  for (let i = 0; i < 3; i += 1) {
    await assert.rejects(getClaudeUsage(), missingCredentials);
  }
  assert.equal(warnings.length, 1, warnings.join('\n'));

  // Signing in rewrites the credential file, which lifts the backoff at once.
  const credsDir = path.join(home, '.claude');
  fs.mkdirSync(credsDir, { recursive: true });
  fs.writeFileSync(path.join(credsDir, '.credentials.json'), 'not json');
  await assert.rejects(getClaudeUsage(), SyntaxError);
  assert.equal(warnings.length, 2, warnings.join('\n'));
});

test('keepalive logs an unchanged failure once', async (t) => {
  const warnings = captureWarnings(t);
  t.mock.method(console, 'log', () => {});
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let reads = 0;
  const keepalive = startClaudeQuotaKeepalive({
    readUsage: async () => {
      reads += 1;
      throw new Error('Claude accessToken was not found. Run claude login.');
    },
  });
  for (let i = 0; i < 3; i += 1) {
    await new Promise(setImmediate);
    t.mock.timers.tick(15 * 60 * 1000);
  }
  await new Promise(setImmediate);
  keepalive.stop();
  assert.ok(reads >= 3, `expected repeated reads, got ${reads}`);
  assert.equal(warnings.length, 1, warnings.join('\n'));
});
