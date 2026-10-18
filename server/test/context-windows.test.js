'use strict';

const assert = require('node:assert/strict');
const { test, after } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-context-windows-'));
const file = path.join(scratchDir, 'context-windows.json');
process.env.RELAY_CONTEXT_WINDOWS_FILE = file;
const { recordContextWindow, contextWindowFor } = require('../lib/context-windows');
const createChatRouter = require('../routes/chat');

after(() => fs.rmSync(scratchDir, { recursive: true, force: true }));

test('windows are persisted per agent and model, including the default model', () => {
  assert.equal(contextWindowFor('claude', 'sonnet'), null);
  recordContextWindow('claude', 'sonnet', 200000);
  recordContextWindow('claude', 'opus', 1000000);
  recordContextWindow('codex', 'sonnet', 400000);
  recordContextWindow('hermes', '', 128000);
  assert.equal(contextWindowFor('claude', 'sonnet'), 200000);
  assert.equal(contextWindowFor('claude', 'opus'), 1000000);
  assert.equal(contextWindowFor('codex', 'sonnet'), 400000);
  assert.equal(contextWindowFor('hermes'), 128000);
  assert.equal(contextWindowFor('hermes', 'default'), 128000);
  assert.equal(contextWindowFor('opencode', 'sonnet'), null);
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8'))['["claude","sonnet"]'], 200000);
});

test('an unchanged size does not rewrite the file; a changed size does', () => {
  recordContextWindow('codex', 'test', 200000);
  const oldTime = new Date('2020-01-01T00:00:00Z');
  fs.utimesSync(file, oldTime, oldTime);
  const before = fs.statSync(file);
  recordContextWindow('codex', 'test', 200000);
  assert.equal(fs.statSync(file).mtimeMs, before.mtimeMs);
  assert.equal(fs.statSync(file).ino, before.ino);
  recordContextWindow('codex', 'test', 400000);
  assert.notEqual(fs.statSync(file).mtimeMs, before.mtimeMs);
  assert.equal(contextWindowFor('codex', 'test'), 400000);
});

test('invalid sizes are ignored', () => {
  for (const size of [0, -1, NaN, Infinity, '200000', 0.4]) {
    recordContextWindow('invalid', 'test', size);
  }
  assert.equal(contextWindowFor('invalid', 'test'), null);
});

test('history returns the window for the session effective model, or null', () => {
  recordContextWindow('codex', 'history-model', 400000);
  const scope = {
    agent: { key: 'codex' },
    workdir: '/repo',
    contextKey: 'main-scope',
    scopeKey: 'named-scope',
    session: { id: 'named' },
  };
  let model = 'history-model';
  const router = createChatRouter({
    resolveAgentScope: () => scope,
    runningScopes: new Set(),
    scopeChains: new Map(),
    finalizeStaleStreamingHistory: () => {},
    sessionPayload: (session) => session,
    readHistory: () => [],
    getSettings(agentKey, scopeKey, contextKey) {
      assert.deepEqual([agentKey, scopeKey, contextKey], [
        'codex', 'named-scope', 'main-scope',
      ]);
      return { model };
    },
    contextWindowFor,
  });
  const handler = router.stack.find((layer) => layer.route?.path === '/api/history')
    .route.stack[0].handle;
  const req = { query: { agent: 'codex', sessionId: 'named' } };
  const res = { json: (body) => body };
  assert.equal(handler(req, res).contextWindow, 400000);
  model = 'unknown-model';
  assert.equal(handler(req, res).contextWindow, null);
});
