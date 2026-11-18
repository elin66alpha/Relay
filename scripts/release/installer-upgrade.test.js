'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const crypto = require('node:crypto');

const updater = path.join(__dirname, '../install/unix/update.sh');

function writeExecutable(file, body) {
  fs.writeFileSync(file, `#!/bin/sh\n${body}`, { mode: 0o755 });
}

test('an upgrade checks Node before touching an existing installation', { skip: process.platform === 'win32' }, (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-upgrade-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, 'bin');
  const install = path.join(root, 'install');
  const marker = path.join(root, 'curl-called');
  fs.mkdirSync(bin);
  fs.mkdirSync(path.join(install, 'server'), { recursive: true });
  fs.writeFileSync(path.join(install, 'server', 'server.js'), 'original');
  fs.writeFileSync(path.join(install, 'server', '.env'), 'fixture');
  writeExecutable(path.join(bin, 'uname'), 'echo Linux\n');
  writeExecutable(path.join(bin, 'node'), 'printf "18\\n"\n');
  writeExecutable(path.join(bin, 'curl'), 'touch "$RELAY_TEST_CURL_MARKER"\nexit 1\n');
  const run = (version) => spawnSync(updater, [], {
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

test('a macOS upgrade keeps server/.env and restarts the backend LaunchAgent', { skip: process.platform === 'win32' }, (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-upgrade-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, 'bin');
  const release = path.join(root, 'release');
  const install = path.join(root, 'install');
  const calls = path.join(root, 'calls');
  const version = '0.1.13';
  const name = `relay-backend-linux-macos-v${version}.tar.gz`;
  for (const dir of [bin, release, path.join(root, 'bundle', 'relay', 'server'), path.join(install, 'server')]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(path.join(root, 'bundle', 'relay', 'server', 'server.js'), 'new');
  const tar = spawnSync('tar', ['-czf', path.join(release, name), '-C', path.join(root, 'bundle'), 'relay']);
  assert.equal(tar.status, 0);
  const digest = crypto.createHash('sha256').update(fs.readFileSync(path.join(release, name))).digest('hex');
  fs.writeFileSync(path.join(install, 'server', 'server.js'), 'old');
  fs.writeFileSync(path.join(install, 'server', '.env'), 'PORT=9999\n');

  writeExecutable(path.join(bin, 'uname'), 'echo Darwin\n');
  // Serves release assets from the fixture directory: curl ... URL -o FILE.
  writeExecutable(path.join(bin, 'curl'), [
    'out=""; url=""',
    'while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done',
    'cp "$RELAY_TEST_RELEASE/${url##*/}" "$out"',
    '',
  ].join('\n'));
  writeExecutable(path.join(bin, 'npm'), 'echo "npm $*" >>"$RELAY_TEST_CALLS"\n');
  writeExecutable(path.join(bin, 'launchctl'), 'echo "launchctl $*" >>"$RELAY_TEST_CALLS"\n');

  // Run the package's local command, including its executable bit and root lookup.
  const installedUpdater = path.join(install, 'scripts/install/unix/update.sh');
  fs.mkdirSync(path.dirname(installedUpdater), { recursive: true });
  fs.copyFileSync(updater, installedUpdater);
  const run = () => spawnSync(installedUpdater, [], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      RELAY_DIR: '',
      RELAY_VERSION: version,
      RELAY_TEST_RELEASE: release,
      RELAY_TEST_CALLS: calls,
    },
  });
  const checksums = path.join(release, 'SHA256SUMS');
  fs.writeFileSync(checksums, `${'0'.repeat(64)}  ${name}\n`);
  const rejected = run();
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /checksum/);
  assert.equal(fs.readFileSync(path.join(install, 'server', 'server.js'), 'utf8'), 'old');
  fs.writeFileSync(checksums, `${digest}  ${name}\n`);
  const result = run();
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Upgraded to 0\.1\.13/);
  assert.match(result.stdout, /scripts\/install\/macos\/setup\.sh/);
  assert.equal(fs.readFileSync(path.join(install, 'server', 'server.js'), 'utf8'), 'new');
  assert.equal(fs.readFileSync(path.join(install, 'server', '.env'), 'utf8'), 'PORT=9999\n');
  const log = fs.readFileSync(calls, 'utf8');
  assert.match(log, /^npm install$/m);
  assert.match(log, /^launchctl kickstart -k gui\/\d+\/dev\.relay\.app\.backend$/m);
});
