'use strict';

const assert = require('node:assert/strict');
const { test, after } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// Point the store at a scratch file before requiring the module (the path is
// resolved from the env at require time, like groups.js).
const scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-agent-settings-'));
process.env.RELAY_AGENT_SETTINGS_FILE = path.join(scratchDir, 'agent-settings.json');

const { getSettings, setSettings, deleteSettings } = require('../lib/agent-settings');

after(() => {
  fs.rmSync(scratchDir, { recursive: true, force: true });
});

const MAIN = '/repo\u0000claude';
const OTHER = `${MAIN}\u0000session-2`;

test('a session without its own settings follows Main until it changes one', () => {
  setSettings('claude', MAIN, { permission: 'plan' });
  assert.equal(getSettings('claude', OTHER, MAIN).permission, 'plan');

  // The first change keeps everything else the session resolved to.
  const own = setSettings('claude', OTHER, { fast: 'on' }, MAIN);
  assert.equal(own.permission, 'plan');
  assert.equal(own.fast, 'on');

  // From then on the two are independent.
  setSettings('claude', MAIN, { permission: 'bypass' });
  assert.equal(getSettings('claude', OTHER, MAIN).permission, 'plan');
  assert.equal(getSettings('claude', MAIN, MAIN).fast, 'off');
});

test('deleting a session drops its settings, leaving the Main fallback', () => {
  setSettings('claude', MAIN, { permission: 'acceptEdits' });
  setSettings('claude', OTHER, { permission: 'plan' }, MAIN);
  deleteSettings(OTHER);
  assert.equal(getSettings('claude', OTHER, MAIN).permission, 'acceptEdits');
});
