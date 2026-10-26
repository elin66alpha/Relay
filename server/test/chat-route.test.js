'use strict';

const assert = require('node:assert/strict');
const { test, before, beforeEach, after } = require('node:test');
const express = require('express');
const createChatRouter = require('../routes/chat');

const WORKDIR = '/tmp/chat-route';
const MAX_PROMPT_BYTES = 32;
const agents = {
  claude: { key: 'claude', label: 'Claude Code' },
  codex: { key: 'codex', label: 'Codex' },
};
const sessions = [
  { id: 'default', name: 'Main' },
  { id: 'review', name: 'Review' },
];
const histories = new Map();
const runCalls = [];
const purgeCalls = [];
const sessionContextKeyFor = (agent, workdir) => `${workdir}\0${agent}`;
const scopeKeyFor = (agent, workdir, sessionId) =>
  `${sessionContextKeyFor(agent, workdir)}${sessionId === 'default' ? '' : `\0${sessionId}`}`;
const resolveChatSession = (_contextKey, id) =>
  sessions.find((session) => session.id === (id || 'default'));
let server;
let base;

before(async () => {
  const app = express();
  app.use(express.json());
  app.use(createChatRouter({
    DEFAULT_AGENT: 'claude',
    MAX_PROMPT_BYTES,
    activeRequests: new Map(),
    runningScopes: new Set(),
    scopeChains: new Map(),
    normalizeDeviceId: () => '',
    getAgent: (key) => agents[key] || null,
    listAgents: () => Object.values(agents),
    requestWorkdir: (req) => req.get('x-workdir'),
    sessionContextKeyFor,
    scopeKeyFor,
    resolveChatSession,
    listChatSessions: () => ({ sessions }),
    sessionPayload: (session) => session,
    touchChatSession: () => {},
    agentRequiredOrUnknownError: (key) => ({
      status: 400,
      body: { error: key ? `unknown agent: ${key}` : 'agent is required' },
    }),
    resolveAgentScope(req, res, { agentKey, sessionId, agentError, beforeWorkdir }) {
      const agent = agents[agentKey];
      if (!agent) {
        const { status, body } = agentError(agentKey);
        res.status(status).json(body);
        return null;
      }
      if (beforeWorkdir && !beforeWorkdir()) return null;
      const workdir = req.get('x-workdir');
      const contextKey = sessionContextKeyFor(agentKey, workdir);
      const session = resolveChatSession(contextKey, sessionId);
      return {
        agent, workdir, contextKey, session,
        scopeKey: scopeKeyFor(agentKey, workdir, session.id),
      };
    },
    readHistory: (scopeKey) => histories.get(scopeKey) || [],
    clearHistory: (scopeKey) => histories.delete(scopeKey),
    finalizeStaleStreamingHistory: () => {},
    getSettings: () => ({ model: 'test-model' }),
    contextWindowFor: () => null,
    async purgeSession(scopeKey, options) {
      purgeCalls.push({ scopeKey, ...options });
      return true;
    },
    clearSession() {
      assert.fail('clearing a conversation must purge the CLI transcript');
    },
    agentTurnDependencies: () => ({}),
    backgroundTurnHandler: () => null,
    createChatResponder: ({ res }) => res,
    updateHistoryMessage(scopeKey, id, updater) {
      const list = histories.get(scopeKey) || [];
      const index = list.findIndex((message) => message.id === id);
      list[index] = updater(list[index]);
    },
    async runAgentTurn({ agentKey, prompt, responder }) {
      runCalls.push({ agentKey, prompt });
      responder.json({ ok: true });
      return prompt === '/compact'
        ? { status: 'done', reply: { message: { context: { used: 9, size: 100 } } } }
        : { status: 'done', reply: { message: {} } };
    },
  }));
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  base = `http://127.0.0.1:${server.address().port}`;
});

beforeEach(() => {
  histories.clear();
  runCalls.length = 0;
  purgeCalls.length = 0;
});

after(() => {
  if (server) server.close();
});

function api(method, urlPath, body, workdir = WORKDIR) {
  return fetch(`${base}${urlPath}`, {
    method,
    headers: { 'Content-Type': 'application/json', 'X-Workdir': workdir },
    body: body ? JSON.stringify(body) : undefined,
  });
}

test('chat refuses prompts over the UTF-8 byte limit before running an agent', async () => {
  for (const prompt of ['x'.repeat(MAX_PROMPT_BYTES + 1), '你'.repeat(11)]) {
    const response = await api('POST', '/api/chat', { agent: 'claude', prompt });
    assert.equal(response.status, 413);
    assert.deepEqual(await response.json(), {
      error: 'prompt exceeds the size limit',
      code: 'PROMPT_TOO_LARGE',
    });
  }
  assert.deepEqual(runCalls, []);
});

test('chat accepts the byte limit and defaults a missing agent to Claude', async () => {
  const prompt = 'é'.repeat(MAX_PROMPT_BYTES / 2);
  const response = await api('POST', '/api/chat', { prompt });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  assert.deepEqual(runCalls, [{ agentKey: 'claude', prompt }]);
});

test('history refuses missing and unknown agents', async () => {
  for (const [query, error] of [
    ['', 'agent is required'],
    ['?agent=missing', 'unknown agent: missing'],
  ]) {
    const response = await api('GET', `/api/history${query}`);
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error });
  }
});

test('chat refuses an unknown agent without starting a turn', async () => {
  const response = await api('POST', '/api/chat', { agent: 'missing', prompt: 'hello' });
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: 'unknown agent: missing' });
  assert.deepEqual(runCalls, []);
});

test('history belongs to the requested workdir, agent, and session', async () => {
  const scopes = [
    [WORKDIR, 'claude', 'default'],
    [WORKDIR, 'claude', 'review'],
    [WORKDIR, 'codex', 'review'],
    [`${WORKDIR}-other`, 'claude', 'review'],
  ];
  for (const [workdir, agent, sessionId] of scopes) {
    histories.set(scopeKeyFor(agent, workdir, sessionId), [{
      id: `${workdir}-${agent}-${sessionId}`,
      role: 'user',
      content: `hello from ${workdir}/${agent}/${sessionId}`,
    }]);
  }
  for (const [workdir, agent, sessionId] of scopes) {
    const query = sessionId === 'default' ? '' : `&sessionId=${sessionId}`;
    const response = await api('GET', `/api/history?agent=${agent}${query}`, undefined, workdir);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      agent,
      workdir,
      session: resolveChatSession('', sessionId),
      messages: histories.get(scopeKeyFor(agent, workdir, sessionId)),
      contextWindow: null,
    });
  }
});

test('clearing a session purges its CLI transcript and only its scoped history', async () => {
  const target = scopeKeyFor('claude', WORKDIR, 'review');
  const other = scopeKeyFor('claude', WORKDIR, 'default');
  histories.set(target, [{ id: 'review-message' }]);
  histories.set(other, [{ id: 'main-message' }]);

  const response = await api('POST', '/api/session/clear', {
    agent: 'claude', sessionId: 'review',
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true, agent: 'claude', workdir: WORKDIR, session: sessions[1], cleared: true,
  });
  assert.deepEqual(purgeCalls, [{ scopeKey: target, agentKey: 'claude', workdir: WORKDIR }]);
  assert.equal(histories.has(target), false);
  assert.deepEqual(histories.get(other), [{ id: 'main-message' }]);
});

test('a compaction moves its context reading onto the latest reply', async () => {
  const scopeKey = scopeKeyFor('claude', WORKDIR, 'default');
  histories.set(scopeKey, [
    { id: 'a', role: 'assistant', metadata: { context: { used: 80, size: 100 } } },
    { id: 'u', role: 'user', metadata: {} },
  ]);
  await api('POST', '/api/chat', { prompt: '/compact', recordHistory: false });
  assert.deepEqual(histories.get(scopeKey)[0].metadata.context, { used: 9, size: 100 });

  histories.get(scopeKey)[0].metadata.context = { used: 80, size: 100 };
  await api('POST', '/api/chat', { prompt: '/compact' });
  assert.deepEqual(
    histories.get(scopeKey)[0].metadata.context,
    { used: 80, size: 100 },
    'only a turn recorded nowhere moves it',
  );
});
