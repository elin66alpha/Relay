'use strict';

// Linux and macOS run one setup (scripts/install/unix). This runs a Quick
// Tunnel install on each (open file access on Linux, isolated on macOS), with
// the service manager and cloudflared faked, and checks that both walk the
// same six steps into their own service manager.

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const repo = path.join(__dirname, '../..');

function writeExecutable(file, body) {
  fs.writeFileSync(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
}

function sandbox(t, uname, fileAccess, { network = '3', tailscale = null, tailscaleExit = 0, web = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-setup-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, 'bin');
  const home = path.join(root, 'home');
  const relay = path.join(root, 'relay');
  const server = path.join(relay, 'server');
  for (const dir of [bin, home, path.join(server, 'scripts'), path.join(server, 'node_modules', 'node-pty'), path.join(server, 'node_modules', 'ws')]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.cpSync(path.join(repo, 'scripts', 'install'), path.join(relay, 'scripts', 'install'), { recursive: true });
  fs.copyFileSync(path.join(repo, 'server', '.env.example'), path.join(server, '.env.example'));
  fs.writeFileSync(path.join(server, 'node_modules', 'node-pty', 'index.js'), 'module.exports = {};');
  fs.writeFileSync(path.join(server, 'scripts', 'create-credential.js'), "console.log('CREDENTIAL ' + process.argv.slice(2).join(' '));");
  // No browser on this host: setup only reminds and carries on.
  fs.writeFileSync(path.join(server, 'scripts', 'check-browser.js'), 'process.exitCode = 1;');

  const calls = path.join(root, 'calls');
  const url = 'https://fake-tunnel.trycloudflare.com';
  writeExecutable(path.join(bin, 'uname'), `echo ${uname}`);
  writeExecutable(path.join(bin, 'zip'), 'exit 0');
  writeExecutable(path.join(bin, 'cloudflared'), 'exit 0');
  // Every agent CLI is present, so step 2 asks nothing.
  for (const cli of ['claude', 'codex', 'agent', 'opencode', 'hermes']) writeExecutable(path.join(bin, cli), 'exit 0');
  // Shadows any host Tailscale: prints the tailnet IP, or fails like one that is not up.
  writeExecutable(
    path.join(bin, 'tailscale'),
    tailscale ? `echo ${tailscale}\nexit ${tailscaleExit}` : 'exit 1',
  );
  // The fake service managers record calls and, when they start the tunnel,
  // write its URL where cloudflared would log it.
  writeExecutable(path.join(bin, 'pm2'), [
    'echo "pm2 $*" >>"$RELAY_TEST_CALLS"',
    'case "$1" in',
    `  start) mkdir -p "$HOME/.pm2/logs"; echo ${url} >"$HOME/.pm2/logs/relay-tunnel-error.log" ;;`,
    '  describe) exit 1 ;;',
    'esac',
  ].join('\n'));
  writeExecutable(path.join(bin, 'launchctl'), [
    'echo "launchctl $*" >>"$RELAY_TEST_CALLS"',
    'case "$1 $3" in',
    `  "kickstart "*tunnel) mkdir -p "$HOME/Library/Logs/Relay"; echo ${url} >"$HOME/Library/Logs/Relay/tunnel.err.log" ;;`,
    '  print*) exit 1 ;;',
    'esac',
  ].join('\n'));

  const platform = uname === 'Darwin' ? 'macos' : 'linux';
  if (web) {
    const webDir = path.join(relay, 'app/shell/build/web');
    fs.mkdirSync(webDir, { recursive: true });
    fs.writeFileSync(path.join(webDir, 'index.html'), 'fixture');
  }
  const result = spawnSync('bash', [path.join(relay, 'scripts', 'install', platform, 'setup.sh'), 'install'], {
    encoding: 'utf8',
    // Step 4: file access. Step 5: network mode answers.
    input: `${web ? 'y\n' : ''}${fileAccess}\n${network}\n`,
    env: { ...process.env, HOME: home, PATH: `${bin}:${process.env.PATH}`, RELAY_TEST_CALLS: calls },
  });
  return { result, home, relay, server, calls: fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8') : '', url };
}

function assertSameSteps(run) {
  assert.equal(run.result.status, 0, run.result.stderr);
  const steps = run.result.stdout.match(/Step \d\/6 · [^\n]+/g);
  assert.deepEqual(steps, [
    'Step 1/6 · System software and server dependencies',
    'Step 2/6 · Agent CLIs',
    'Step 3/6 · Web client',
    'Step 4/6 · File access',
    'Step 5/6 · Network mode',
    'Step 6/6 · Device credential (choose a password for the QR)',
  ]);
  assert.match(run.result.stdout, new RegExp(`CREDENTIAL --url ${run.url}`));
  assert.match(run.result.stdout, /No Chrome, Chromium or Edge found\. Relay's Browser page needs one/);
  const env = fs.readFileSync(path.join(run.server, '.env'), 'utf8');
  assert.match(env, /^RELAY_TUNNEL_MODE=quick$/m);
  assert.match(env, /^CLOUDFLARED_ARGS=tunnel --url http:\/\/127\.0\.0\.1:8787$/m);
}

test('Linux setup runs the six steps, leaves file access open and starts PM2', { skip: process.platform === 'win32' }, (t) => {
  const run = sandbox(t, 'Linux', '1');
  assertSameSteps(run);
  assert.match(fs.readFileSync(path.join(run.server, '.env'), 'utf8'), /^RELAY_WORKSPACE_ROOT=$/m);
  assert.match(run.calls, /^pm2 start ecosystem\.config\.js --update-env$/m);
});

test('macOS setup runs the same six steps, isolates file access and starts both LaunchAgents', { skip: process.platform === 'win32' }, (t) => {
  const run = sandbox(t, 'Darwin', '2');
  assertSameSteps(run);
  const workspace = path.join(fs.realpathSync(run.relay), 'workspace');
  assert.ok(fs.statSync(workspace).isDirectory());
  assert.ok(fs.readFileSync(path.join(run.server, '.env'), 'utf8').includes(`\nRELAY_WORKSPACE_ROOT=${workspace}\n`));
  assert.match(run.calls, /^launchctl kickstart -k gui\/\d+\/dev\.relay\.app\.backend$/m);
  assert.match(run.calls, /^launchctl kickstart -k gui\/\d+\/dev\.relay\.app\.tunnel$/m);
  const plist = fs.readFileSync(path.join(run.home, 'Library', 'LaunchAgents', 'dev.relay.app.tunnel.plist'), 'utf8');
  assert.match(plist, /<string>tunnel<\/string>\s*<string>--url<\/string>\s*<string>http:\/\/127\.0\.0\.1:8787<\/string>/);
});

test('Tailscale mode serves the tailnet IP and needs no tunnel', { skip: process.platform === 'win32' }, (t) => {
  const run = sandbox(t, 'Linux', '1', { network: '4', tailscale: '100.101.102.103' });
  assert.equal(run.result.status, 0, run.result.stderr);
  const env = fs.readFileSync(path.join(run.server, '.env'), 'utf8');
  assert.match(env, /^PUBLIC_BASE_URL=http:\/\/100\.101\.102\.103:8787$/m);
  assert.match(env, /^HOST=100\.101\.102\.103$/m);
  assert.match(env, /^RELAY_TUNNEL_MODE=none$/m);
  assert.match(run.result.stdout, /CREDENTIAL --url http:\/\/100\.101\.102\.103:8787/);
});

test('Tailscale Web uses a configured HTTPS proxy or disables Web for native-only installs', { skip: process.platform === 'win32' }, (t) => {
  for (const proxy of ['relay.example.test', '']) {
    const run = sandbox(t, 'Darwin', '1', { network: `4\n${proxy}`, tailscale: '100.101.102.103', web: true });
    assert.equal(run.result.status, 0, run.result.stderr);
    const env = fs.readFileSync(path.join(run.server, '.env'), 'utf8');
    assert.match(env, /^HOST=100\.101\.102\.103$/m);
    const url = proxy ? 'https://relay.example.test' : 'http://100.101.102.103:8787';
    assert.ok(env.split('\n').includes(`PUBLIC_BASE_URL=${url}`));
    assert.ok(env.split('\n').includes(`RELAY_SERVE_WEB=${proxy ? 1 : 0}`));
    assert.ok(run.result.stdout.includes(`CREDENTIAL --url ${url}`));
  }
});

test('Tailscale mode without a tailnet returns to the network menu', { skip: process.platform === 'win32' }, (t) => {
  const run = sandbox(t, 'Linux', '1', { network: '4\n3' });
  assert.equal(run.result.status, 0, run.result.stderr);
  assert.match(run.result.stdout, /not connected to a tailnet/);
  assert.equal(run.result.stdout.match(/4\) Tailscale/g).length, 2);
  assert.match(fs.readFileSync(path.join(run.server, '.env'), 'utf8'), /^RELAY_TUNNEL_MODE=quick$/m);
});

test('Tailscale mode rejects non-CGNAT output or failing tailscale CLI', { skip: process.platform === 'win32' }, (t) => {
  const failing = sandbox(t, 'Linux', '1', {
    network: '4\n3',
    tailscale: '100.101.102.103',
    tailscaleExit: 1,
  });
  assert.equal(failing.result.status, 0, failing.result.stderr);
  assert.equal(failing.result.stdout.match(/4\) Tailscale/g).length, 2);

  for (const tailscale of ['100.200.1.2', '100.100.256.1', '100.100.1.999']) {
    const invalid = sandbox(t, 'Linux', '1', { network: '4\n3', tailscale });
    assert.equal(invalid.result.status, 0, invalid.result.stderr);
    assert.equal(invalid.result.stdout.match(/4\) Tailscale/g).length, 2);
  }
});
