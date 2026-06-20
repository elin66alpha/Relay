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
  selectLoginUrl,
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
  child.killedSignal = '';
  child.kill = (signal) => {
    child.killedSignal = signal;
  };
  return child;
}

test('scriptCommand quotes login args for script -qfec', () => {
  assert.equal(
    scriptCommand(['codex', 'login', '--device-auth']),
    "'codex' 'login' '--device-auth'",
  );
});

test('selectLoginUrl prefers auth URLs over incidental links', () => {
  assert.deepEqual(
    selectLoginUrl('codex', [
      'https://docs.example.test/setup',
      'https://auth.openai.com/oauth/authorize?client_id=codex',
    ]).url,
    'https://auth.openai.com/oauth/authorize?client_id=codex',
  );
  assert.deepEqual(
    selectLoginUrl('agy', [
      'https://example.test/help',
      'https://accounts.google.com/o/oauth2/auth?client_id=agy.',
    ]).url,
    'https://accounts.google.com/o/oauth2/auth?client_id=agy',
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

  child.stdout.emit(
    'data',
    'Docs https://example.test/docs Open https://auth.openai.com/oauth/authorize?client_id=codex to continue\n',
  );
  child.stderr.emit('data', 'Troubleshooting: https://example.test/help\n');
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
    'https://auth.openai.com/oauth/authorize?client_id=codex',
  );
  assert.equal(
    events.filter((event) => event.type === 'login_url').at(-1).data.url,
    'https://auth.openai.com/oauth/authorize?client_id=codex',
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

test('login manager kills a running login when the last listener disconnects', () => {
  const child = fakeChild();
  const manager = createAgentLoginManager({
    commandExists: () => true,
    randomUUID: () => 'login-disconnect',
    spawn() {
      return child;
    },
  });

  const session = manager.start('codex');
  const unsubscribe = manager.subscribe(session.id, () => {});
  unsubscribe();

  const status = manager.status(session.id);
  assert.equal(child.killedSignal, 'SIGTERM');
  assert.equal(status.status, 'error');
  assert.match(status.error, /client disconnected/i);
});

test('login manager cleanup reaps expired running sessions', () => {
  let now = 1000;
  const child = fakeChild();
  const manager = createAgentLoginManager({
    commandExists: () => true,
    maxRunningMs: 50,
    now: () => now,
    randomUUID: () => 'login-timeout',
    spawn() {
      return child;
    },
  });

  const session = manager.start('codex');
  now += 51;
  manager.cleanup();

  const status = manager.status(session.id);
  assert.equal(child.killedSignal, 'SIGTERM');
  assert.equal(status.status, 'error');
  assert.match(status.error, /timed out/i);
});

test('login manager rejects unsupported and missing CLIs clearly', () => {
  const manager = createAgentLoginManager({ commandExists: () => false });

  assert.throws(() => manager.start('hermes'), /not supported/);
  assert.throws(() => manager.start('codex'), /not installed/);
});
