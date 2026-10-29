'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

test('a Linux upgrade checks Node before touching an existing installation', { skip: process.platform !== 'linux' }, (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-upgrade-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, 'bin');
  const install = path.join(root, 'install');
  const marker = path.join(root, 'curl-called');
  fs.mkdirSync(bin);
  fs.mkdirSync(path.join(install, 'server'), { recursive: true });
  fs.writeFileSync(path.join(install, 'server', 'server.js'), 'original');
  fs.writeFileSync(path.join(install, 'server', '.env'), 'fixture');
  fs.writeFileSync(path.join(bin, 'node'), '#!/bin/sh\nprintf "18\\n"\n', { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'curl'), '#!/bin/sh\ntouch "$RELAY_TEST_CURL_MARKER"\nexit 1\n', { mode: 0o755 });
  const run = (version) => spawnSync('bash', [path.join(__dirname, '../install/linux/install.sh')], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, RELAY_DIR: install, RELAY_VERSION: version, RELAY_TEST_CURL_MARKER: marker },
  });
  const rejected = run('0.1.10');
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /Node\.js 22\+/);
  assert.equal(fs.existsSync(marker), false, 'rejects before downloading');
  assert.equal(fs.readFileSync(path.join(install, 'server', 'server.js'), 'utf8'), 'original');

  run('0.1.9');
  assert.equal(fs.existsSync(marker), true, 'older releases retain their original runtime requirement');
});
