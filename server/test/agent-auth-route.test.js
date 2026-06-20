'use strict';

const assert = require('node:assert/strict');
const { after, before, test } = require('node:test');
const express = require('express');

const createAgentAuthRouter = require('../routes/agent-auth');

let server;
let base;
const submitted = [];

const loginManager = {
  start(agent) {
    return { id: 'session-1', agent };
  },
  subscribe(_sessionId, listener) {
    listener({
      type: 'login_started',
      data: { sessionId: 'session-1', agent: 'codex' },
    });
    listener({
      type: 'login_url',
      data: {
        sessionId: 'session-1',
        agent: 'codex',
        url: 'https://example.test/login',
      },
    });
    listener({
      type: 'login_done',
      data: { sessionId: 'session-1', agent: 'codex' },
    });
    return () => {};
  },
  submitCode(sessionId, code) {
    submitted.push({ sessionId, code });
  },
  status(sessionId) {
    return {
      sessionId,
      agent: 'codex',
      status: 'done',
      url: 'https://example.test/login',
      error: '',
    };
  },
};

before(async () => {
  const app = express();
  app.use(express.json());
  app.use(
    createAgentAuthRouter({
      getAgent: (key) => ({ key, label: key }),
      loginManager,
    }),
  );
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  const { port } = server.address();
  base = `http://127.0.0.1:${port}`;
});

after(() => {
  if (server) server.close();
});

test('login start streams SSE events from the login manager', async () => {
  const response = await fetch(`${base}/api/agent-auth/login/start?agent=codex`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /text\/event-stream/);
  const text = await response.text();
  assert.match(text, /event: login_started/);
  assert.match(text, /event: login_url/);
  assert.match(text, /https:\/\/example\.test\/login/);
  assert.match(text, /event: login_done/);
});

test('submit code forwards the code to the login manager without echoing it', async () => {
  const response = await fetch(`${base}/api/agent-auth/login/code`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId: 'session-1', code: 'secret-code' }),
  });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.deepEqual(submitted[0], {
    sessionId: 'session-1',
    code: 'secret-code',
  });
});
