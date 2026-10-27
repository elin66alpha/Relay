'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

test('Windows setup status lists device summaries without bearer or CLI credentials', () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-setup-status-'));
  try {
    const tokenFile = path.join(scratch, 'tokens.json');
    fs.writeFileSync(tokenFile, JSON.stringify([{
      id: 'fixture-id', token: 'fixture-secret-bearer', label: 'Fixture device', revoked: false,
    }]));
    const result = spawnSync(process.execPath, [path.join(__dirname, '../scripts/windows-setup.js')], {
      encoding: 'utf8', timeout: 15000,
      env: {
        ...process.env, HOME: scratch, USERPROFILE: scratch,
        APPDATA: scratch, XDG_CONFIG_HOME: scratch, CODEX_HOME: scratch,
        RELAY_CURSOR_CONFIG_DIR: path.join(scratch, 'cursor'),
        RELAY_TOKENS_FILE: tokenFile, RELAY_MODEL_DISCOVERY: '0',
        OPENAI_API_KEY: 'fixture-secret-api-key', CURSOR_API_KEY: 'fixture-secret-cursor',
      },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(!result.stdout.includes('fixture-secret'));
    const status = JSON.parse(result.stdout);
    assert.deepEqual(status.agents.map((agent) => agent.key), ['claude', 'codex', 'cursor', 'opencode', 'hermes']);
    assert.equal(status.tokens[0].id, 'fixture-id');
    assert.equal(status.tokens[0].label, 'Fixture device');
    assert.ok(!Object.hasOwn(status.tokens[0], 'token'));
    for (const agent of status.agents) {
      assert.deepEqual(Object.keys(agent).sort(), ['authed', 'installed', 'key', 'label', 'login']);
    }
  } finally { fs.rmSync(scratch, { recursive: true, force: true }); }
});
