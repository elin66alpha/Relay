'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

test('a CLI missing from PATH is found in ~/.local/bin', { skip: process.platform === 'win32' }, () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-cli-paths-'));
  const bin = path.join(home, '.local', 'bin');
  fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(path.join(bin, 'claude'), '#!/bin/sh\n', { mode: 0o755 });
  const saved = { HOME: process.env.HOME, PATH: process.env.PATH };
  process.env.HOME = home;
  process.env.PATH = '';
  try {
    const { commandExists, locateBin } = require('../lib/cli-paths');
    assert.equal(locateBin('claude'), path.join(bin, 'claude'));
    assert.equal(commandExists('codex'), false);
  } finally {
    Object.assign(process.env, saved);
    fs.rmSync(home, { recursive: true, force: true });
  }
});
