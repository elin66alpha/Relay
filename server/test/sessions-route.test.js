'use strict';

const assert = require('node:assert/strict');
const { test, before, after } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const express = require('express');

const scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-sessions-route-'));
// The store path is resolved from the env at require time, like agent-settings.js.
process.env.RELAY_CHAT_SESSIONS_FILE = path.join(scratchDir, 'chat-sessions.json');
const sessions = require('../lib/chat-sessions');
const createSessionsRouter = require('../routes/sessions');

const WORKDIR = '/tmp/sessions-int';
const CONTEXT = `${WORKDIR}\0claude`;
const runningScopes = new Set();
const scopeChains = new Map();
let server;
let base;

before(async () => {
  const app = express();
  app.use(express.json());
  app.use(createSessionsRouter({
    ...sessions,
    agentPayload: (agent) => agent,
    clearHistory: () => {},
    deleteSettings: () => {},
    getSettings: () => ({}),
    purgeSession: async () => true,
    setSettings: () => {},
    resolveAgentScope(req, res, { agentKey, beforeWorkdir }) {
      if (beforeWorkdir && !beforeWorkdir()) return null;
      const workdir = req.get('x-workdir');
      return {
        agent: { key: agentKey },
        workdir,
        contextKey: `${workdir}\0${agentKey}`,
      };
    },
    runningScopes,
    scopeChains,
    scopeKeyFor: sessions.scopeKeyFor,
  }));
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => {
  if (server) server.close();
  fs.rmSync(scratchDir, { recursive: true, force: true });
});

function rename(body, workdir = WORKDIR) {
  return fetch(`${base}/api/sessions/rename`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Workdir': workdir },
    body: JSON.stringify({ agent: 'claude', ...body }),
  });
}

test('rename normalizes and persists a running session label without changing selection or order', async () => {
  const first = sessions.createChatSession(CONTEXT, 'First').activeSessionId;
  sessions.createChatSession(CONTEXT, 'Second');
  const before = sessions.listChatSessions(CONTEXT);
  const scopeKey = sessions.sessionScopeKey(CONTEXT, first);
  runningScopes.add(scopeKey);
  scopeChains.set(scopeKey, Promise.resolve());

  const response = await rename({ sessionId: first, name: '  New\n\t label  ' });
  assert.equal(response.status, 200);
  const expected = {
    ...before,
    sessions: before.sessions.map((session) =>
      session.id === first ? { ...session, name: 'New label' } : session,
    ),
  };
  assert.deepEqual(await response.json(), {
    ok: true,
    agent: { key: 'claude' },
    workdir: WORKDIR,
    ...expected,
  });
  const listed = await fetch(`${base}/api/sessions?agent=claude`, {
    headers: { 'X-Workdir': WORKDIR },
  });
  assert.deepEqual((await listed.json()).sessions, expected.sessions);
  assert.deepEqual(sessions.listChatSessions(CONTEXT), expected);
});

test('rename uses the create name limit and returns null for a missing session', () => {
  const contextKey = `${WORKDIR}\0codex`;
  const rawName = `  Long\n\t${'name'.repeat(30)}  `;
  const created = sessions.createChatSession(contextKey, rawName);
  const expectedName = created.sessions[0].name;
  const target = sessions.createChatSession(contextKey, 'Target').activeSessionId;
  const renamed = sessions.renameChatSession(contextKey, target, rawName);
  assert.equal(renamed.sessions.find((session) => session.id === target).name, expectedName);
  assert.equal(expectedName.length, 80);
  assert.equal(sessions.renameChatSession(contextKey, 'missing', 'New'), null);
  assert.deepEqual(sessions.listChatSessions(contextKey), renamed);
});

test('rename protects Main', async () => {
  const before = sessions.listChatSessions(CONTEXT);
  const response = await rename({ sessionId: sessions.MAIN_SESSION_ID, name: 'New' });
  assert.equal(response.status, 400);
  assert.equal((await response.json()).code, 'SESSION_PROTECTED');
  assert.deepEqual(sessions.listChatSessions(CONTEXT), before);
});

test('rename requires a session id', async () => {
  const response = await rename({ name: 'New' });
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: 'sessionId is required' });
});

test('rename rejects missing and whitespace-only names', async () => {
  const before = sessions.listChatSessions(CONTEXT);
  for (const name of [undefined, '', ' \n\t\u2003 ']) {
    const response = await rename({ sessionId: before.activeSessionId, name });
    assert.equal(response.status, 400);
    assert.equal((await response.json()).code, 'SESSION_NAME_REQUIRED');
  }
  assert.deepEqual(sessions.listChatSessions(CONTEXT), before);
});

test('rename reports sessions missing from the requested agent or workdir', async () => {
  const before = sessions.listChatSessions(CONTEXT);
  for (const [body, workdir] of [
    [{ sessionId: 'missing' }, WORKDIR],
    [{ sessionId: before.activeSessionId, agent: 'codex' }, WORKDIR],
    [{ sessionId: before.activeSessionId }, `${WORKDIR}-other`],
  ]) {
    const response = await rename({ ...body, name: 'New' }, workdir);
    assert.equal(response.status, 404);
    assert.equal((await response.json()).code, 'SESSION_NOT_FOUND');
  }
  assert.deepEqual(sessions.listChatSessions(CONTEXT), before);
});

test('swarm sessions are hidden from GET /api/sessions, never become active, have their own cap, and can be deleted', async () => {
  const swarmCtx = `${WORKDIR}\0swarm-test`;
  const listed = await (await fetch(`${base}/api/sessions?agent=swarm-test`, {
    headers: { 'X-Workdir': WORKDIR },
  })).json();
  assert.ok(Array.isArray(listed.features) && listed.features.includes('swarm-sessions'));
  const mainId = listed.activeSessionId;

  const createRes = await fetch(`${base}/api/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Workdir': WORKDIR },
    body: JSON.stringify({ agent: 'swarm-test', name: 'Swarm: Alpha', kind: 'swarm' }),
  });
  assert.equal(createRes.status, 200);
  const created = await createRes.json();
  assert.ok(created.sessionId);
  assert.equal(created.activeSessionId, mainId, 'creating a swarm session does not activate it');
  assert.ok(!created.sessions.some((s) => s.id === created.sessionId), 'swarm session is hidden from list');

  // touchChatSession must not activate a swarm session either.
  sessions.touchChatSession(swarmCtx, created.sessionId);
  assert.equal(sessions.listChatSessions(swarmCtx).activeSessionId, mainId);
  // Explicitly resolvable by id.
  assert.equal(sessions.resolveChatSession(swarmCtx, created.sessionId).kind, 'swarm');

  // Swarm sessions do not count toward MAX_SESSIONS (8).
  for (let i = 0; i < sessions.MAX_SESSIONS; i += 1) {
    assert.ok(sessions.createChatSession(swarmCtx, `Swarm ${i}`, { kind: 'swarm' }));
  }
  // Regular sessions can still be created up to MAX_SESSIONS.
  assert.ok(sessions.createChatSession(swarmCtx, 'Regular 1'));

  // Deleting a swarm session by explicit id succeeds.
  const delRes = await fetch(`${base}/api/sessions/delete`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Workdir': WORKDIR },
    body: JSON.stringify({ agent: 'swarm-test', sessionId: created.sessionId }),
  });
  assert.equal(delRes.status, 200);
  assert.equal(sessions.resolveChatSession(swarmCtx, created.sessionId), null);
});
