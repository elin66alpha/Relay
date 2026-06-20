'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

const {
  agyTokenPath,
  createAgentLoginManager,
  scriptCommand,
} = require('../lib/agent-login');

function fakeChild() {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.stdin = {
    writable: true,
    writes: [],
    write(value) {
      this.writes.push(value);
    },
  };
  return child;
}

test('scriptCommand quotes login args for script -qfec', () => {
  assert.equal(
    scriptCommand(['codex', 'login', '--device-auth']),
    "'codex' 'login' '--device-auth'",
  );
});

test('login manager streams URL events and writes submitted code to PTY stdin', () => {
  let spawned;
  const child = fakeChild();
  const manager = createAgentLoginManager({
    commandExists: () => true,
    randomUUID: () => 'login-1',
    spawn(command, args, options) {
      spawned = { command, args, options };
      return child;
    },
  });

  const session = manager.start('codex');
  const events = [];
  manager.subscribe(session.id, (event) => events.push(event));

  child.stdout.emit('data', 'Open https://example.test/device to continue\n');
  manager.submitCode(session.id, 'abc123');
  child.emit('exit', 0);

  assert.equal(spawned.command, 'script');
  assert.deepEqual(spawned.args, [
    '-qfec',
    "'codex' 'login' '--device-auth'",
    '/dev/null',
  ]);
  assert.equal(spawned.options.stdio[0], 'pipe');
  assert.equal(child.stdin.writes[0], 'abc123\n');
  assert.ok(events.some((event) => event.type === 'login_started'));
  assert.deepEqual(
    events.find((event) => event.type === 'login_url').data.url,
    'https://example.test/device',
  );
  assert.ok(events.some((event) => event.type === 'login_done'));
});

test('agy login completes when the browser OAuth token file appears', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-agy-login-'));
  const child = fakeChild();
  const manager = createAgentLoginManager({
    commandExists: () => true,
    fs,
    homeDir: home,
    pollIntervalMs: 5,
    randomUUID: () => 'agy-login-1',
    spawn() {
      return child;
    },
  });
  const events = [];
  const session = manager.start('agy');
  manager.subscribe(session.id, (event) => events.push(event));

  child.stdout.emit(
    'data',
    'Open https://accounts.google.com/o/oauth2/auth?client_id=agy to continue\n',
  );
  assert.equal(
    events.find((event) => event.type === 'login_started').data.requiresCode,
    false,
  );
  assert.throws(
    () => manager.submitCode(session.id, 'unused-code'),
    /does not accept/,
  );

  fs.mkdirSync(path.dirname(agyTokenPath(home)), { recursive: true });
  fs.writeFileSync(agyTokenPath(home), 'oauth-token\n');
  await new Promise((resolve) => setTimeout(resolve, 20));

  assert.deepEqual(
    events.find((event) => event.type === 'login_url').data.url,
    'https://accounts.google.com/o/oauth2/auth?client_id=agy',
  );
  assert.ok(events.some((event) => event.type === 'login_done'));
  fs.rmSync(home, { recursive: true, force: true });
});

test('login manager rejects unsupported and missing CLIs clearly', () => {
  const manager = createAgentLoginManager({ commandExists: () => false });

  assert.throws(() => manager.start('hermes'), /not supported/);
  assert.throws(() => manager.start('codex'), /not installed/);
});
