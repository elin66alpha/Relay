'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const test = require('node:test');

const { createRelayClient } = require('../lib/relay-client');
const { plainText } = require('../lib/terminal');
const { createTools, splitPath } = require('../lib/tools');

// A stand-in backend: each test sets routes['METHOD /path'] to a handler.
async function startBackend(routes) {
  const requests = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const url = new URL(req.url, 'http://x');
      const raw = Buffer.concat(chunks);
      const request = {
        method: req.method,
        path: url.pathname,
        query: Object.fromEntries(url.searchParams),
        headers: req.headers,
        raw,
        body: req.headers['content-type'] === 'application/json' ? JSON.parse(raw) : null,
      };
      requests.push(request);
      const route = routes[`${req.method} ${url.pathname}`];
      if (!route) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'no route' }));
        return;
      }
      route(request, res);
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const state = { workdir: '' };
  const client = createRelayClient({
    baseUrl: `http://127.0.0.1:${server.address().port}`,
    token: 'tok',
    deviceId: 'relay-mcp-test',
    deviceName: 'Relay MCP (test)',
    getWorkdir: () => state.workdir,
  });
  const tools = createTools({ getClient: () => client, state, machineName: 'pc' });
  const call = (name, args = {}) => tools.find((tool) => tool.name === name).handler(args);
  return { requests, state, call, close: () => server.close() };
}

function json(body, status = 200) {
  return (_req, res) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(body));
  };
}

function sse(res, type, payload) {
  res.write(`event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`);
}

const base = {
  'GET /api/workdir': json({ dir: '/w', busy: false }),
  'GET /api/sessions': json({ activeSessionId: 's2', sessions: [] }),
};

test('relay_chat returns a reply that finishes within the wait', async (t) => {
  const backend = await startBackend({
    ...base,
    'POST /api/chat': (req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      sse(res, 'ready', { requestId: req.body.requestId });
      sse(res, 'agent_delta', { text: 'hel' });
      sse(res, 'agent_done', { message: { content: 'hello' } });
      res.end();
    },
  });
  t.after(backend.close);
  const result = await backend.call('relay_chat', { agent: 'claude', prompt: 'hi' });
  assert.equal(result.status, 'done');
  assert.equal(result.reply.content, 'hello');
  assert.equal(result.sessionId, 's2');
  assert.equal(result.workdir, '/w');
  const chat = backend.requests.find((req) => req.path === '/api/chat');
  assert.equal(chat.headers.authorization, 'Bearer tok');
  assert.equal(chat.headers['x-workdir'], '/w');
  assert.equal(chat.headers['x-device-id'], 'relay-mcp-test');
  assert.deepEqual(
    { agent: chat.body.agent, prompt: chat.body.prompt, sessionId: chat.body.sessionId },
    { agent: 'claude', prompt: 'hi', sessionId: 's2' },
  );
});

test('a long turn returns running, then relay_task reads its progress and reply', async (t) => {
  let requestId = '';
  let finished = false;
  const backend = await startBackend({
    ...base,
    'POST /api/chat': (req, res) => {
      requestId = req.body.requestId;
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      sse(res, 'ready', { requestId });
      // Never finishes on this connection.
    },
    'GET /api/history': (req, res) => {
      assert.equal(req.query.sessionId, 's2');
      json({
        agent: 'claude',
        workdir: '/w',
        session: { id: 's2', name: 'Two' },
        messages: [
          { id: `${requestId}:user`, role: 'user', content: 'hi', createdAt: new Date().toISOString() },
          {
            id: `${requestId}:assistant`,
            role: 'assistant',
            content: finished ? 'x'.repeat(300) : '',
            createdAt: new Date(Date.now() - 5000).toISOString(),
            updatedAt: new Date().toISOString(),
            metadata: finished ? {} : { streaming: true, progressLines: ['Read a.js', 'Edit b.js'] },
          },
        ],
      })(req, res);
    },
  });
  t.after(backend.close);
  const started = await backend.call('relay_chat', { agent: 'claude', prompt: 'hi', waitSeconds: 1 });
  assert.equal(started.status, 'running');
  assert.equal(started.requestId, requestId);

  const running = await backend.call('relay_task', { requestId, agent: 'claude', sessionId: 's2', workdir: '/w' });
  assert.equal(running.status, 'running');
  assert.deepEqual(running.progress, ['Read a.js', 'Edit b.js']);

  finished = true;
  const done = await backend.call('relay_task', { requestId, agent: 'claude', sessionId: 's2', workdir: '/w', maxChars: 200 });
  assert.equal(done.status, 'done');
  assert.equal(done.reply.content.length, 200);
  assert.equal(done.reply.nextOffset, 200);
  assert.equal(done.elapsedSeconds, 5);
});

test('backend errors keep their code', async (t) => {
  const backend = await startBackend({
    'POST /api/sessions': json({ error: 'session limit reached (max 8)', code: 'SESSION_LIMIT_REACHED' }, 409),
  });
  t.after(backend.close);
  await assert.rejects(
    backend.call('relay_sessions', { action: 'create', agent: 'claude', name: 'x' }),
    (err) => err.code === 'SESSION_LIMIT_REACHED' && err.status === 409,
  );
});

test('relay_workdir set switches the workdir sent with later calls', async (t) => {
  const backend = await startBackend({
    'POST /api/workdir': (req, res) => json({ ok: true, dir: `${req.body.path}/canonical`, created: req.body.create })(req, res),
    'GET /api/agent-settings': json({ ok: true, settings: { model: 'opus' } }),
    'POST /api/agent-settings': (req, res) => json({ ok: true, settings: req.body })(req, res),
  });
  t.after(backend.close);
  const result = await backend.call('relay_workdir', { action: 'set', path: '/p', create: true });
  assert.equal(result.dir, '/p/canonical');
  assert.equal(backend.state.workdir, '/p/canonical');
  await backend.call('relay_agent_settings', { action: 'set', agent: 'codex', effort: 'high', model: 'gpt' });
  const settings = backend.requests.at(-1);
  assert.equal(settings.headers['x-workdir'], '/p/canonical');
  assert.deepEqual(settings.body, { agent: 'codex', effort: 'high', model: 'gpt' });
});

test('relay_files reads text in pages, reports binary, and writes by directory and name', async (t) => {
  const backend = await startBackend({
    'GET /api/fs/download': (req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/octet-stream' });
      res.end(req.query.path === 'bin' ? Buffer.from([1, 0, 2]) : 'abcdefghij'.repeat(30));
    },
    'POST /api/fs/upload': json({ ok: true, entry: { name: 'n.txt' } }),
  });
  t.after(backend.close);
  const text = await backend.call('relay_files', { action: 'read', path: 'a.txt', offset: 295, maxChars: 200 });
  assert.equal(text.content, 'fghij');
  assert.equal(text.truncated, undefined);
  const binary = await backend.call('relay_files', { action: 'read', path: 'bin' });
  assert.deepEqual({ binary: binary.binary, bytes: binary.bytes }, { binary: true, bytes: 3 });

  await backend.call('relay_files', { action: 'write', path: '/srv/app/n.txt', content: 'hi' });
  const upload = backend.requests.at(-1);
  assert.deepEqual(upload.query, { path: '/srv/app', name: 'n.txt' });
  assert.equal(upload.raw.toString(), 'hi');
  await backend.call('relay_files', { action: 'write', path: 'notes/n.txt', content: 'hi' });
  assert.deepEqual(backend.requests.at(-1).query, { path: 'notes', name: 'n.txt', mkdir: '1' });
});

test('relay_swarm_chat returns the round replies', async (t) => {
  let requestId = '';
  const backend = await startBackend({
    ...base,
    'POST /api/group/chat': (req, res) => {
      requestId = req.body.requestId;
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      sse(res, 'ready', { requestId });
      sse(res, 'group_done', { turns: [] });
      res.end();
    },
    'GET /api/group/history': (req, res) => json({
      workdir: '/w',
      runningRequestId: null,
      messages: [
        { id: 'older:human', role: 'user', content: 'old' },
        { id: `${requestId}:human`, role: 'user', content: '@codex hi' },
        { id: `${requestId}.0.0.codex:assistant`, role: 'assistant', agent: 'codex', content: 'yo' },
      ],
    })(req, res),
  });
  t.after(backend.close);
  const result = await backend.call('relay_swarm_chat', { groupId: 'g1', prompt: '@codex hi' });
  assert.equal(result.status, 'done');
  assert.deepEqual(result.messages.map((m) => m.content), ['@codex hi', 'yo']);
});

test('splitPath follows the backend path flavour', () => {
  assert.deepEqual(splitPath('C:\\work\\a.txt'), { dir: 'C:\\work', name: 'a.txt', absolute: true });
  assert.deepEqual(splitPath('a.txt'), { dir: '', name: 'a.txt', absolute: false });
});

test('plainText strips terminal escapes', () => {
  assert.equal(plainText('\x1b[1;32mok\x1b[0m\r\n\x1b]0;title\x07$ '), 'ok\n$ ');
});
