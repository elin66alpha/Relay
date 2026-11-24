'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const bridge = path.join(__dirname, '../scripts/setup-status.js');

// A home with no agent logins, so the result does not depend on the host.
function fixtureEnv(scratch, extra = {}) {
  return {
    ...process.env, HOME: scratch, USERPROFILE: scratch,
    APPDATA: scratch, XDG_CONFIG_HOME: scratch, CODEX_HOME: scratch,
    RELAY_CURSOR_CONFIG_DIR: path.join(scratch, 'cursor'),
    RELAY_TOKENS_FILE: path.join(scratch, 'tokens.json'), RELAY_MODEL_DISCOVERY: '0',
    ...extra,
  };
}

test('setup status lists device summaries without bearer or CLI credentials', () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-setup-status-'));
  try {
    const tokenFile = path.join(scratch, 'tokens.json');
    fs.writeFileSync(tokenFile, JSON.stringify([{
      id: 'fixture-id', token: 'fixture-secret-bearer', label: 'Fixture device', revoked: false,
    }]));
    const result = spawnSync(process.execPath, [bridge], {
      encoding: 'utf8', timeout: 15000,
      env: fixtureEnv(scratch, {
        OPENAI_API_KEY: 'fixture-secret-api-key', CURSOR_API_KEY: 'fixture-secret-cursor',
      }),
    });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(!result.stdout.includes('fixture-secret'));
    const status = JSON.parse(result.stdout);
    assert.deepEqual(status.agents.map((agent) => agent.key), ['claude', 'codex', 'cursor', 'opencode', 'agy', 'hermes']);
    assert.equal(status.tokens[0].id, 'fixture-id');
    assert.equal(status.tokens[0].label, 'Fixture device');
    assert.ok(!Object.hasOwn(status.tokens[0], 'token'));
    for (const agent of status.agents) {
      assert.deepEqual(Object.keys(agent).sort(), ['authed', 'installed', 'key', 'label', 'login']);
    }
  } finally { fs.rmSync(scratch, { recursive: true, force: true }); }
});

test('setup status --agents prints one tab-separated line per agent for the Unix menu', () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-setup-status-'));
  try {
    // An executable agy in ~/.local/bin, where its installer puts it.
    const bin = path.join(scratch, '.local', 'bin');
    fs.mkdirSync(bin, { recursive: true });
    const agy = path.join(bin, process.platform === 'win32' ? 'agy.exe' : 'agy');
    fs.writeFileSync(agy, '#!/bin/sh\n', { mode: 0o755 });
    const result = spawnSync(process.execPath, [bridge, '--agents'], {
      encoding: 'utf8', timeout: 15000,
      env: fixtureEnv(scratch, { PATH: path.dirname(process.execPath) }),
    });
    assert.equal(result.status, 0, result.stderr);
    const rows = result.stdout.trim().split('\n').map((line) => line.split('\t'));
    assert.deepEqual(rows.map((row) => row[0]), ['claude', 'codex', 'cursor', 'opencode', 'agy', 'hermes']);
    for (const row of rows) assert.equal(row.length, 4);
    assert.deepEqual(rows[4], ['agy', 'Antigravity', '1', 'agy acp --login']);
  } finally { fs.rmSync(scratch, { recursive: true, force: true }); }
});
