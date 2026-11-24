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

// An installed backend (macOS unless `uname` says Linux) at the previous version and a release archive of
// `version` served by a fake curl. `answers` is whether the restarted backend
// answers on its port; `npmExit` is what the fake npm exits with.
function upgradeFixture(t, { answers = true, npmExit = 0, latest = '', uname = 'Darwin', prepare = () => {} } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-upgrade-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, 'bin');
  const release = path.join(root, 'release');
  const install = path.join(root, 'install');
  const home = path.join(root, 'home');
  const calls = path.join(root, 'calls');
  const version = '0.1.13';
  const name = `relay-backend-linux-macos-v${version}.tar.gz`;
  const bundle = path.join(root, 'bundle', 'relay');
  for (const dir of [bin, release, home, path.join(bundle, 'server', 'lib'), path.join(install, 'server', 'lib')]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  // The release ships these scripts, so its own adapter restarts the backend.
  fs.cpSync(path.join(__dirname, '../install'), path.join(bundle, 'scripts', 'install'), { recursive: true });
  fs.writeFileSync(path.join(bundle, 'server', 'server.js'), 'new');
  fs.writeFileSync(path.join(bundle, 'server', 'lib', 'added.js'), 'new');
  const tar = spawnSync('tar', ['-czf', path.join(release, name), '-C', path.dirname(bundle), 'relay']);
  assert.equal(tar.status, 0);
  const digest = crypto.createHash('sha256').update(fs.readFileSync(path.join(release, name))).digest('hex');
  fs.writeFileSync(path.join(release, 'SHA256SUMS'), `${digest}  ${name}\n`);

  fs.writeFileSync(path.join(install, 'server', 'server.js'), 'old');
  fs.writeFileSync(path.join(install, 'server', 'lib', 'dropped.js'), 'old');
  fs.writeFileSync(path.join(install, 'server', 'package.json'), '{\n  "name": "relay-server",\n  "version": "0.1.12"\n}\n');
  fs.writeFileSync(path.join(install, 'server', '.env'), 'PORT=9999\n');
  fs.writeFileSync(path.join(install, 'server', 'tokens.json'), 'kept');
  // Run the package's local command, including its executable bit and root lookup.
  const updater = path.join(install, 'scripts/install/unix/update.sh');
  fs.mkdirSync(path.dirname(updater), { recursive: true });
  fs.copyFileSync(path.join(__dirname, '../install/unix/update.sh'), updater);

  prepare(install);
  writeExecutable(path.join(bin, 'uname'), `echo ${uname}\n`);
  // Release assets come from the fixture directory (curl ... URL -o FILE);
  // -w prints the latest release tag; the backend port answers or refuses.
  writeExecutable(path.join(bin, 'curl'), [
    'out=""; url=""; w=""',
    'while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -w) w=1; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done',
    '[ -z "$w" ] || { echo "https://github.com/x/releases/tag/v$RELAY_TEST_LATEST"; exit 0; }',
    `case "$url" in http://127.0.0.1:*) exit ${answers ? 0 : 7} ;; esac`,
    'cp "$RELAY_TEST_RELEASE/${url##*/}" "$out"',
    '',
  ].join('\n'));
  writeExecutable(path.join(bin, 'npm'), `echo "npm $* in $PWD" >>"$RELAY_TEST_CALLS"\nexit ${npmExit}\n`);
  writeExecutable(path.join(bin, 'launchctl'), 'echo "launchctl $*" >>"$RELAY_TEST_CALLS"\n');
  writeExecutable(path.join(bin, 'pm2'), 'echo "pm2 $*" >>"$RELAY_TEST_CALLS"\n');
  writeExecutable(path.join(bin, 'sleep'), 'exit 0\n');

  const result = spawnSync(updater, [], {
    encoding: 'utf8',
    env: {
      ...process.env,
      HOME: home,
      PATH: `${bin}:${process.env.PATH}`,
      RELAY_DIR: '',
      RELAY_VERSION: latest ? '' : version,
      RELAY_TEST_LATEST: latest,
      RELAY_TEST_RELEASE: release,
      RELAY_TEST_CALLS: calls,
    },
  });
  const read = (file) => fs.readFileSync(path.join(install, file), 'utf8');
  const exists = (file) => fs.existsSync(path.join(install, file));
  return { result, home, release, name, read, exists, calls: fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8') : '' };
}

test('an upgrade rejects a download that does not match the release checksum', { skip: process.platform === 'win32' }, (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-upgrade-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, 'bin');
  const release = path.join(root, 'release');
  const install = path.join(root, 'install');
  const name = 'relay-backend-linux-macos-v0.1.13.tar.gz';
  for (const dir of [bin, release, path.join(install, 'server')]) fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(release, name), 'not the release');
  fs.writeFileSync(path.join(release, 'SHA256SUMS'), `${'0'.repeat(64)}  ${name}\n`);
  fs.writeFileSync(path.join(install, 'server', 'server.js'), 'old');
  fs.writeFileSync(path.join(install, 'server', '.env'), 'PORT=9999\n');
  writeExecutable(path.join(bin, 'curl'), [
    'out=""; url=""',
    'while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done',
    'cp "$RELAY_TEST_RELEASE/${url##*/}" "$out"',
    '',
  ].join('\n'));
  const result = spawnSync('bash', [updater], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, RELAY_DIR: install, RELAY_VERSION: '0.1.13', RELAY_TEST_RELEASE: release },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /checksum/);
  assert.equal(fs.readFileSync(path.join(install, 'server', 'server.js'), 'utf8'), 'old');
});

test('a macOS upgrade keeps server/.env and restarts the backend LaunchAgent', { skip: process.platform === 'win32' }, (t) => {
  const run = upgradeFixture(t);
  assert.equal(run.result.status, 0, run.result.stderr);
  assert.match(run.result.stdout, /Upgraded to 0\.1\.13/);
  assert.match(run.result.stdout, /scripts\/install\/macos\/setup\.sh/);
  assert.equal(run.read('server/server.js'), 'new');
  assert.equal(run.read('server/lib/added.js'), 'new');
  assert.equal(run.exists('server/lib/dropped.js'), false, 'a file the release dropped goes with its folder');
  assert.equal(run.read('server/.env'), 'PORT=9999\n');
  assert.equal(run.read('server/tokens.json'), 'kept');
  assert.equal(run.exists('.relay-update-old') || run.exists('.relay-update-new'), false);
  // Dependencies install in the staged copy, before the installation changes.
  assert.match(run.calls, /^npm ci --omit=dev in .*\/\.relay-update-new\/server$/m);
  assert.match(run.calls, /^launchctl kickstart -k gui\/\d+\/dev\.relay\.app\.backend$/m);
  assert.doesNotMatch(run.calls, /dev\.relay\.app\.tunnel/, 'the tunnel keeps running, and its URL');
  const plist = fs.readFileSync(path.join(run.home, 'Library', 'LaunchAgents', 'dev.relay.app.backend.plist'), 'utf8');
  const node = plist.match(/<key>ProgramArguments<\/key>\s*<array>\s*<string>([^<]+)<\/string>/)[1];
  assert.ok(path.isAbsolute(node) && path.basename(node) === 'node', `the LaunchAgent runs an absolute node, got ${node}`);
  assert.ok(plist.includes(`<string>${path.dirname(node)}:`), 'that node\'s folder leads the service PATH');
});

test('an upgrade that is already on the latest release changes nothing', { skip: process.platform === 'win32' }, (t) => {
  const run = upgradeFixture(t, { latest: '0.1.12' });
  assert.equal(run.result.status, 0, run.result.stderr);
  assert.match(run.result.stdout, /Relay 0\.1\.12 is already the latest version/);
  assert.equal(run.read('server/server.js'), 'old');
  assert.equal(run.calls, '', 'nothing is downloaded, installed or restarted');
});

test('a failed dependency install leaves the installation unchanged', { skip: process.platform === 'win32' }, (t) => {
  const run = upgradeFixture(t, { npmExit: 1 });
  assert.notEqual(run.result.status, 0);
  assert.match(run.result.stderr, /Nothing was changed/);
  assert.equal(run.read('server/server.js'), 'old');
  assert.equal(run.exists('server/lib/dropped.js'), true);
  assert.equal(run.exists('.relay-update-new'), false);
  assert.doesNotMatch(run.calls, /launchctl/);
});

test('a new version that does not answer is replaced by the previous one', { skip: process.platform === 'win32' }, (t) => {
  const run = upgradeFixture(t, { answers: false });
  assert.notEqual(run.result.status, 0);
  assert.match(run.result.stderr, /did not start within 30 seconds; putting Relay 0\.1\.12 back/);
  assert.equal(run.read('server/server.js'), 'old');
  assert.equal(run.read('server/lib/dropped.js'), 'old');
  assert.equal(run.exists('server/lib/added.js'), false);
  assert.equal(run.read('server/tokens.json'), 'kept');
  assert.equal(run.exists('.relay-update-old'), false);
  assert.equal(run.calls.match(/^launchctl kickstart -k gui\/\d+\/dev\.relay\.app\.backend$/gm).length, 2, 'restarted on the new, then the previous version');
});

test('a Linux upgrade re-registers only the backend with PM2', { skip: process.platform === 'win32' }, (t) => {
  const run = upgradeFixture(t, { uname: 'Linux' });
  assert.equal(run.result.status, 0, run.result.stderr);
  assert.equal(run.read('server/server.js'), 'new');
  assert.match(run.calls, /^pm2 delete relay-server$/m);
  assert.match(run.calls, /^pm2 start ecosystem\.config\.js --only relay-server --update-env$/m);
  assert.doesNotMatch(run.calls, /relay-tunnel/, 'the tunnel keeps running, and its URL');
});

test('an update interrupted while swapping files is undone by the next run', { skip: process.platform === 'win32' }, (t) => {
  const run = upgradeFixture(t, {
    npmExit: 1,
    // As if the previous run stopped after moving server.js and adding a file.
    prepare(install) {
      const old = path.join(install, '.relay-update-old');
      fs.mkdirSync(path.join(old, 'server'), { recursive: true });
      fs.renameSync(path.join(install, 'server', 'server.js'), path.join(old, 'server', 'server.js'));
      fs.writeFileSync(path.join(install, 'server', 'server.js'), 'half');
      fs.writeFileSync(path.join(install, 'server', 'lib', 'half.js'), 'half');
      fs.writeFileSync(path.join(old, '.added'), 'server/lib/half.js\n');
    },
  });
  assert.match(run.result.stdout, /Restoring the version an interrupted update left/);
  assert.equal(run.read('server/server.js'), 'old');
  assert.equal(run.exists('server/lib/half.js'), false);
  assert.equal(run.exists('.relay-update-old'), false);
});
