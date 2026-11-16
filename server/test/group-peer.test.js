'use strict';

// Swarm members on another Relay backend (a peer). Backend A is the group
// router with the real runAgentTurn and peer client; the peer is an in-process
// HTTP server speaking the endpoints a real backend serves (agents, sessions,
// SSE chat, cancel), so every request A sends to it can be inspected.

const assert = require('node:assert/strict');
const { test, before, after } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const express = require('express');

const scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-group-peer-'));
process.env.RELAY_GROUPS_FILE = path.join(scratchDir, 'groups.json');
process.env.RELAY_HISTORY_FILE = path.join(scratchDir, 'history.json');
process.env.RELAY_SWARM_MAX_HOPS = '2';

const history = require('../lib/history');
const { sessionScopeKey } = require('../lib/chat-sessions');
const { runAgentTurn } = require('../lib/agent-turn');
const groups = require('../lib/groups');
const { createPeerClient, normalizeBaseUrl, peerIdFor } = require('../lib/peer-client');
const createGroupRouter = require('../routes/group');

const SEP = '\0';
const WORKDIR = '/tmp/group-peer';
const PEER_TOKEN = 'peer-secret-token-1f6c2a9d';
const AGENTS = {
  claude: { key: 'claude', label: 'Claude Code', run: () => {} },
  codex: { key: 'codex', label: 'Codex', run: () => {} },
};

// Everything A writes where a token could leak to: shared-stream events,
// per-turn broadcasts, response bodies and console output.
const leakSinks = [];
const sentEvents = [];
const localCalls = [];
const localReplies = new Map();

for (const method of ['log', 'warn', 'error', 'info']) {
  const original = console[method];
  console[method] = (...args) => {
    leakSinks.push(args.map(String).join(' '));
    original.apply(console, args);
  };
}

function createFakePeer({ token = PEER_TOKEN } = {}) {
  const state = {
    requests: [],
    sessions: new Map(),
    replies: new Map(),
    held: null,
    created: 0,
  };
  const contextFor = (agent) => {
    if (!state.sessions.has(agent)) {
      state.sessions.set(agent, { activeSessionId: 'main', sessions: [{ id: 'main', name: 'Main' }] });
    }
    return state.sessions.get(agent);
  };
  const app = express();
  app.use(express.json());
  app.use((req, res, next) => {
    state.requests.push({
      method: req.method,
      path: req.path,
      body: req.body,
      workdir: req.get('x-workdir') || '',
      deviceId: req.get('x-device-id') || '',
      authorization: req.get('authorization') || '',
    });
    if (req.get('authorization') !== `Bearer ${token}`) {
      return res.status(401).json({ error: 'unauthorized' });
    }
    return next();
  });
  const workdirOf = (req) => req.get('x-workdir') || '/peer/default';
  app.get('/api/agents', (_req, res) => res.json({
    defaultAgent: 'claude',
    agents: [
      { key: 'claude', label: 'Claude Code', installed: true, authed: true, usable: true },
      { key: 'codex', label: 'Codex', installed: true, authed: true, usable: true },
    ],
  }));
  app.get('/api/sessions', (req, res) =>
    res.json({ ok: true, workdir: workdirOf(req), ...contextFor(req.query.agent) }));
  app.post('/api/sessions', (req, res) => {
    const context = contextFor(req.body.agent);
    state.created += 1;
    const session = { id: `peer-session-${state.created}`, name: req.body.name };
    context.sessions.unshift(session);
    context.activeSessionId = session.id;
    res.json({ ok: true, workdir: workdirOf(req), ...context });
  });
  app.post('/api/sessions/active', (req, res) => {
    const context = contextFor(req.body.agent);
    context.activeSessionId = req.body.sessionId;
    res.json({ ok: true, workdir: workdirOf(req), ...context });
  });
  app.post('/api/sessions/delete', (req, res) => {
    const context = contextFor(req.body.agent);
    context.sessions = context.sessions.filter((s) => s.id !== req.body.sessionId);
    res.json({ ok: true, deletedSessionId: req.body.sessionId });
  });
  app.post('/api/session/clear', (_req, res) => res.json({ ok: true }));
  app.post('/api/chat/cancel', (req, res) => {
    if (state.held) state.held();
    res.json({ ok: true, requestId: req.body.requestId });
  });
  app.post('/api/chat', async (req, res) => {
    // A real backend makes the conversation's session the active one.
    contextFor(req.body.agent).activeSessionId = req.body.sessionId;
    const write = (type, payload) =>
      res.write(`event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`);
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    write('ready', { ok: true, requestId: req.body.requestId });
    if (state.holdNext) {
      state.holdNext = false;
      await new Promise((resolve) => { state.held = resolve; });
      state.held = null;
      write('agent_cancelled', { requestId: req.body.requestId });
      return res.end();
    }
    const reply = state.replies.get(req.body.agent) || `peer reply from ${req.body.agent}`;
    write('agent_progress', { line: 'thinking on the peer' });
    write('agent_delta', { text: reply.slice(0, 5) });
    write('agent_delta', { text: reply.slice(5) });
    write('agent_done', { message: { role: 'assistant', content: reply } });
    return res.end();
  });
  return {
    state,
    async listen() {
      await new Promise((resolve) => { this.server = app.listen(0, '127.0.0.1', resolve); });
      this.baseUrl = `http://127.0.0.1:${this.server.address().port}`;
      this.peerId = peerIdFor(normalizeBaseUrl(this.baseUrl));
      return this;
    },
    close() {
      return new Promise((resolve) => this.server.close(resolve));
    },
  };
}

function buildContext() {
  const sessionContextKeyFor = (agentKey, workdir) => `${workdir}${SEP}${agentKey}`;
  const scopeKeyFor = (agentKey, workdir, sessionId) =>
    sessionScopeKey(sessionContextKeyFor(agentKey, workdir), sessionId);
  const runningScopes = new Set();
  const scopeChains = new Map();
  const agentTurnDependencies = () => ({
    broadcastScope: (type, payload) => leakSinks.push(JSON.stringify({ type, payload })),
    enqueueScope: (_key, fn) => fn(),
    getSettings: () => ({}),
    recordContextWindow: () => {},
    runningScopes,
    scopeChains,
    touchChatSession: () => {},
    updateHistoryMessage: history.updateHistoryMessage,
    upsertHistoryMessage: history.upsertHistoryMessage,
    async runAgent(agentKey, prompt, onEvent) {
      localCalls.push({ agentKey, prompt });
      const reply = localReplies.get(agentKey) || `local reply from ${agentKey}`;
      onEvent({ type: 'delta', text: reply });
      return reply;
    },
  });
  return {
    ...groups,
    MAX_PROMPT_BYTES: 100 * 1024,
    activeRequests: new Map(),
    agentTurnDependencies,
    clearHistory: history.clearHistory,
    createPeerClient,
    purgeSession: async () => true,
    finalizeStaleStreamingHistory: history.finalizeStaleStreamingHistory,
    getAgent: (key) => AGENTS[key] || null,
    normalizeDeviceId: (value) => String(value || ''),
    notifyTaskCompletion: () => {},
    readHistory: history.readHistory,
    requestWorkdir: (req) => req.get('x-workdir') || WORKDIR,
    runAgentTurn,
    runningScopes,
    scopeChains,
    scopeKeyFor,
    sendEvent: (type, payload) => {
      sentEvents.push({ type, payload });
      leakSinks.push(JSON.stringify({ type, payload }));
    },
    sendWorkdirError: (res, err) => res.status(400).json({ error: err.message }),
    sessionContextKeyFor,
    upsertHistoryMessage: history.upsertHistoryMessage,
    validateWorkdir: (value) => ({ dir: String(value), created: false }),
  };
}

let server;
let base;
let peer;

before(async () => {
  const app = express();
  app.use(express.json());
  app.use(createGroupRouter(buildContext()));
  await new Promise((resolve) => { server = app.listen(0, '127.0.0.1', resolve); });
  base = `http://127.0.0.1:${server.address().port}`;
  peer = await createFakePeer().listen();
});

after(async () => {
  if (server) server.close();
  if (peer) await peer.close();
  fs.rmSync(scratchDir, { recursive: true, force: true });
});

async function api(method, urlPath, body) {
  const res = await fetch(`${base}${urlPath}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      'X-Workdir': WORKDIR,
      'X-Device-Id': 'device-test-0001',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  leakSinks.push(text);
  return { status: res.status, body: JSON.parse(text) };
}

const credential = (target = peer, token = PEER_TOKEN) =>
  ({ name: 'Peer B', baseUrl: `${target.baseUrl}/`, token });
const remote = (agent, target = peer) => `${target.peerId}:${agent}`;

async function createSwarm(name, members, extra = {}) {
  const { status, body } = await api('POST', '/api/groups', {
    name,
    members,
    peers: [credential()],
    configs: { [remote('claude')]: { workdir: '/peer/project', nickname: '' } },
    ...extra,
  });
  assert.equal(status, 200, JSON.stringify(body));
  return body.group;
}

function messagesOf(group) {
  return history.readHistory(sessionScopeKey(`${WORKDIR}${SEP}group:${group.id}`));
}

test('adding a remote member creates its own session on the peer and restores the active one', async () => {
  const before = peer.state.requests.length;
  const group = await createSwarm('Mixed', ['claude', remote('claude')]);
  assert.deepEqual(group.members, ['claude', remote('claude')]);
  assert.deepEqual(group.peers, {
    [peer.peerId]: { name: 'Peer B', baseUrl: peer.baseUrl },
  });
  const config = group.memberConfigs[remote('claude')];
  assert.equal(config.workdir, '/peer/project');
  assert.match(config.sessionId, /^peer-session-/);
  const context = peer.state.sessions.get('claude');
  assert.equal(context.activeSessionId, 'main');
  assert.equal(context.sessions.find((s) => s.id === config.sessionId).name, 'Swarm: Mixed');
  const calls = peer.state.requests.slice(before).map((r) => `${r.method} ${r.path}`);
  assert.deepEqual(calls, [
    'GET /api/agents',
    'GET /api/sessions',
    'POST /api/sessions',
    'POST /api/sessions/active',
  ]);
});

test('a remote member turn streams from the peer into the swarm transcript', async () => {
  const group = await createSwarm('Remote turn', [remote('claude')]);
  const sessionId = group.memberConfigs[remote('claude')].sessionId;
  const { status, body } = await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: `hello @${remote('claude')}`,
    peers: [credential()],
  });
  assert.equal(status, 200);
  assert.deepEqual(body.turns, [{ agent: remote('claude'), status: 'done' }]);
  const reply = messagesOf(group).find((m) => m.role === 'assistant');
  assert.equal(reply.content, 'peer reply from claude');
  assert.equal(reply.metadata.author, remote('claude'));
  assert.equal(reply.metadata.agentLabel, 'Claude Code (Peer B)');
  assert.deepEqual(reply.metadata.progressLines, ['thinking on the peer']);
  const chat = peer.state.requests.find(
    (r) => r.path === '/api/chat' && r.body.sessionId === sessionId,
  );
  assert.equal(chat.workdir, '/peer/project');
  assert.equal(chat.deviceId, 'device-test-0001');
  assert.equal(chat.body.agent, 'claude');
  assert.match(chat.body.prompt, /Human: hello/);
  assert.equal(peer.state.sessions.get('claude').activeSessionId, 'main');
});

test('remote and local members summon each other by @mention', async () => {
  const group = await createSwarm('Relay race', ['codex', remote('claude')]);
  peer.state.replies.set('claude', 'over to you @codex');
  localReplies.set('codex', `your turn again @${remote('claude')}`);
  try {
    const { body } = await api('POST', '/api/group/chat', {
      groupId: group.id,
      prompt: `start @${remote('claude')}`,
      peers: [credential()],
    });
    assert.deepEqual(body.turns.map((t) => t.agent), [
      remote('claude'), 'codex', remote('claude'),
    ]);
  } finally {
    peer.state.replies.clear();
    localReplies.clear();
  }
});

test('Stop forwards the cancel to the peer with the same request id and work tree', async () => {
  const group = await createSwarm('Cancel', [remote('claude')]);
  peer.state.holdNext = true;
  const requestId = 'round-cancel-1';
  const round = api('POST', '/api/group/chat', {
    groupId: group.id,
    requestId,
    prompt: `@${remote('claude')} take your time`,
    peers: [credential()],
  });
  while (!peer.state.held) await new Promise((resolve) => setTimeout(resolve, 10));
  const cancel = await api('POST', '/api/group/chat/cancel', { requestId });
  assert.equal(cancel.status, 200);
  const { body } = await round;
  assert.equal(body.cancelled, true);
  assert.deepEqual(body.turns, [{ agent: remote('claude'), status: 'cancelled' }]);
  const forwarded = peer.state.requests.find((r) => r.path === '/api/chat/cancel');
  const chat = peer.state.requests.find(
    (r) => r.path === '/api/chat' && r.body.requestId.startsWith(`${requestId}.`),
  );
  assert.equal(forwarded.body.requestId, chat.body.requestId);
  assert.equal(forwarded.workdir, '/peer/project');
});

async function roundErrors(group, peers) {
  const { body } = await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: `@claude and @${remote('claude')}`,
    peers,
  });
  const replies = messagesOf(group).filter((m) => m.role === 'assistant');
  const byAuthor = Object.fromEntries(replies.map((m) => [m.metadata.author, m]));
  return { body, local: byAuthor.claude, remote: byAuthor[remote('claude')] };
}

test('without a credential the remote member fails with PEER_NOT_LINKED and the rest run', async () => {
  const group = await createSwarm('Unlinked', ['claude', remote('claude')]);
  const { body, local, remote: failed } = await roundErrors(group, undefined);
  assert.deepEqual(body.turns.map((t) => t.status), ['done', 'error']);
  assert.equal(local.content, 'local reply from claude');
  assert.equal(failed.metadata.errorCode, 'PEER_NOT_LINKED');
  assert.match(failed.content, /Peer B is not connected on this device/);
});

test('a rejected credential fails with PEER_UNAUTHORIZED and the rest run', async () => {
  const group = await createSwarm('Bad token', ['claude', remote('claude')]);
  const { local, remote: failed } = await roundErrors(group, [credential(peer, 'wrong-token')]);
  assert.equal(local.content, 'local reply from claude');
  assert.equal(failed.metadata.errorCode, 'PEER_UNAUTHORIZED');
  assert.match(failed.content, /refused this device's credential/);
});

test('an unreachable peer fails with PEER_UNREACHABLE and the rest run', async () => {
  const gone = await createFakePeer().listen();
  const { status, body: created } = await api('POST', '/api/groups', {
    name: 'Gone',
    members: ['claude', remote('claude', gone)],
    peers: [credential(gone)],
  });
  assert.equal(status, 200);
  await gone.close();
  const { body } = await api('POST', '/api/group/chat', {
    groupId: created.group.id,
    prompt: `@claude and @${remote('claude', gone)}`,
    peers: [credential(gone)],
  });
  assert.deepEqual(body.turns.map((t) => t.status), ['done', 'error']);
  const failed = messagesOf(created.group).find(
    (m) => m.metadata.author === remote('claude', gone),
  );
  assert.equal(failed.metadata.errorCode, 'PEER_UNREACHABLE');
  assert.match(failed.content, /is unreachable/);
});

test('adding a member the peer does not have or cannot be reached creates nothing', async () => {
  const swarmsBefore = groups.listGroups(WORKDIR).length;
  const sessionsBefore = peer.state.sessions.get('claude').sessions.length;
  const unknown = await api('POST', '/api/groups', {
    members: [remote('claude'), `${peer.peerId}:hermes`],
    peers: [credential()],
  });
  assert.equal(unknown.status, 400);
  assert.equal(unknown.body.code, 'PEER_UNKNOWN_AGENT');
  const unlinked = await api('POST', '/api/groups', { members: ['claude', remote('claude')] });
  assert.equal(unlinked.status, 400);
  assert.equal(unlinked.body.code, 'PEER_NOT_LINKED');
  const refused = await api('POST', '/api/groups', {
    members: [remote('claude')],
    peers: [credential(peer, 'wrong-token')],
  });
  assert.equal(refused.status, 502);
  assert.equal(refused.body.code, 'PEER_UNAUTHORIZED');
  assert.equal(groups.listGroups(WORKDIR).length, swarmsBefore);
  assert.equal(peer.state.sessions.get('claude').sessions.length, sessionsBefore);
});

test('removing a machine\'s last member drops its peer and the peer session', async () => {
  const group = await createSwarm('Shrink', ['claude', remote('claude')]);
  const sessionId = group.memberConfigs[remote('claude')].sessionId;
  const { body } = await api('POST', '/api/groups/members', {
    groupId: group.id,
    members: ['claude'],
    peers: [credential()],
  });
  assert.deepEqual(body.group.peers, {});
  assert.ok(!peer.state.sessions.get('claude').sessions.some((s) => s.id === sessionId));
});

test('deleting a swarm deletes the peer session when the credential is sent, and works without it', async () => {
  const linked = await createSwarm('Delete linked', [remote('claude')]);
  const sessionId = linked.memberConfigs[remote('claude')].sessionId;
  const first = await api('POST', '/api/groups/delete', { groupId: linked.id, peers: [credential()] });
  assert.equal(first.status, 200);
  assert.ok(!peer.state.sessions.get('claude').sessions.some((s) => s.id === sessionId));
  const unlinked = await createSwarm('Delete unlinked', [remote('claude')]);
  const second = await api('POST', '/api/groups/delete', { groupId: unlinked.id });
  assert.equal(second.status, 200);
  assert.equal(groups.getGroup(WORKDIR, unlinked.id), null);
});

test('the peer token never reaches state, history, events, responses or logs', () => {
  history.flushHistory();
  const files = [process.env.RELAY_GROUPS_FILE, process.env.RELAY_HISTORY_FILE];
  for (const file of files) {
    assert.ok(fs.existsSync(file), `${file} was written`);
    assert.ok(!fs.readFileSync(file, 'utf8').includes(PEER_TOKEN), `${file} holds the token`);
  }
  assert.ok(leakSinks.length > 0);
  for (const text of leakSinks) assert.ok(!text.includes(PEER_TOKEN), text);
  // The token did travel to the peer, so the check above is not vacuous.
  assert.ok(peer.state.requests.some((r) => r.authorization === `Bearer ${PEER_TOKEN}`));
});
