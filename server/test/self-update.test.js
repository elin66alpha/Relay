'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');
const express = require('express');

const createMetaRouter = require('../routes/meta');
const {
  UpdateError,
  backendVersion,
  startBackendUpdate,
} = require('../lib/self-update');

function fakeSpawn(calls) {
  return (file, args, options) => {
    calls.push({ file, args, options });
    const child = new EventEmitter();
    child.unref = () => {};
    return child;
  };
}

test('a source checkout is never updated', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-update-'));
  fs.mkdirSync(path.join(root, '.git'));
  const calls = [];
  assert.throws(
    () => startBackendUpdate({ root, run: fakeSpawn(calls) }),
    (err) => err.code === 'UPDATE_UNSUPPORTED',
  );
  assert.equal(calls.length, 0);
});

test('the updater is detached, targets this installation and runs once', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay update '));
  const calls = [];
  const run = fakeSpawn(calls);

  startBackendUpdate({ root, platform: 'linux', run, now: 1e9 });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].file, 'sh');
  assert.match(calls[0].args[1], /releases\/latest\/download\/install\.sh/);
  assert.equal(calls[0].options.env.RELAY_DIR, root);
  assert.equal(calls[0].options.detached, true);

  assert.throws(
    () => startBackendUpdate({ root, platform: 'linux', run, now: 1e9 + 1000 }),
    (err) => err.code === 'UPDATE_RUNNING',
  );

  startBackendUpdate({ root, platform: 'win32', run, now: 2e9 });
  assert.equal(calls[1].file, 'cmd.exe');
  assert.ok(
    calls[1].args[0].includes(
      `-File "${path.join(root, 'scripts', 'install', 'windows', 'update.ps1')}"`,
    ),
  );
});

test('/api/machine reports the version and /api/backend-update starts the update', async () => {
  let outcome = null;
  const app = express();
  app.use(
    createMetaRouter({
      backendVersion,
      machineInfo: async () => ({ cpu: 'fixture' }),
      startBackendUpdate: () => {
        if (outcome) throw outcome;
      },
    }),
  );
  const server = await new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  try {
    const base = `http://127.0.0.1:${server.address().port}`;
    const machine = await (await fetch(`${base}/api/machine`)).json();
    assert.deepEqual(machine, { cpu: 'fixture', version: backendVersion });

    const started = await fetch(`${base}/api/backend-update`, { method: 'POST' });
    assert.equal(started.status, 202);

    outcome = new UpdateError('UPDATE_UNSUPPORTED', 'source checkout');
    const refused = await fetch(`${base}/api/backend-update`, { method: 'POST' });
    assert.equal(refused.status, 409);
    assert.equal((await refused.json()).code, 'UPDATE_UNSUPPORTED');
  } finally {
    server.close();
  }
});
