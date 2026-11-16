'use strict';

const assert = require('node:assert/strict');
const { test, beforeEach } = require('node:test');

process.env.RELAY_MODEL_DISCOVERY = '0';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const sessions = {};
const pools = { agy: {}, claude: {}, codex: {}, opencode: {}, hermes: {}, cursor: {} };
// Every Cursor process pool agents.js creates, with the options it passed and
// the scope keys it was asked to forget.
const cursorCreated = [];
const cursorSentVia = [];
const cursorConfigDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-cursor-config-'));
process.env.RELAY_CURSOR_CONFIG_DIR = cursorConfigDir;
// The catalog agents.js composes Cursor's config options from.
const cursorCatalog = [
  { id: 'default', label: 'Auto' },
  {
    id: 'big',
    label: 'Big',
    effortOption: 'effort',
    efforts: [{ id: 'low', label: 'Low' }, { id: 'high', label: 'High' }],
    defaultEffort: 'high',
  },
];
const agyContexts = {};
// Replace factories before agents.js captures them. The session store is in
// memory because its production filename has no environment override.
const replacements = {
  '../lib/json-store': {
    createJsonStore: () => ({
      load: () => sessions,
      mutate: (fn) => fn(sessions),
    }),
  },
  '../lib/usage': {
    readAgyContext: async (sessionId) => agyContexts[sessionId] || null,
  },
  '../lib/claude-session-pool': { createClaudeSessionPool: () => pools.claude },
  '../lib/codex-session-pool': { createCodexSessionPool: () => pools.codex },
  '../lib/model-discovery': {
    groupAgyModels: require('../lib/model-discovery').groupAgyModels,
    discoverModels: (agentKey) => (agentKey === 'cursor' ? cursorCatalog : null),
    recordCursorCatalog: () => {},
  },
  '../lib/acp-session-pool': {
    createAcpSessionPool: (options) => {
      if (options.agentKey !== 'cursor') return pools[options.agentKey];
      const created = { options, forgotten: [] };
      cursorCreated.push(created);
      return {
        send: (call) => {
          cursorSentVia.push(created);
          return pools.cursor.send(call);
        },
        forget: async (key) => {
          created.forgotten.push(key);
        },
        shutdown: async () => {},
      };
    },
  },
};
const savedModules = new Map();
for (const [name, exports] of Object.entries(replacements)) {
  const filename = require.resolve(name);
  savedModules.set(filename, require.cache[filename]);
  require.cache[filename] = { id: filename, filename, loaded: true, exports };
}
let agents;
try {
  agents = require('../lib/agents');
} finally {
  for (const [filename, saved] of savedModules) {
    if (saved) require.cache[filename] = saved;
    else delete require.cache[filename];
  }
}
const { runAgent, AgentCancelledError, AgentAuthError } = agents;

beforeEach(() => {
  for (const key of Object.keys(sessions)) delete sessions[key];
  for (const key of Object.keys(agyContexts)) delete agyContexts[key];
  for (const pool of Object.values(pools)) {
    pool.send = async () => assert.fail('unexpected pool call');
  }
});

const cases = [
  {
    agent: 'claude',
    settings: { model: 'claude-sonnet-4-6', effort: 'low', permission: 'plan', fast: 'on' },
    options: {
      sdkOptions: {
        model: 'claude-sonnet-4-6', effort: 'low', permissionMode: 'plan',
        settings: { fastMode: true },
      },
    },
    messages: [
      { type: 'assistant', message: { id: 'first', content: [{ type: 'text', text: 'Checking' }] } },
      { type: 'assistant', message: { id: 'first', content: [{ type: 'text', text: 'Checking files' }] } },
      { type: 'assistant', message: { id: 'last', content: [{ type: 'text', text: 'Done' }] } },
    ],
    reply: 'Done',
  },
  {
    agent: 'codex',
    settings: { model: 'gpt-5.4', effort: 'high', permission: 'read-only', fast: 'on' },
    options: {
      model: 'gpt-5.4', effort: 'high', sandbox: 'read-only', fixedKey: 'read-only',
      approvalPolicy: 'never', serviceTier: 'fast',
    },
    messages: [
      { type: 'delta', itemId: 'first', text: 'Checking' },
      { type: 'delta', itemId: 'first', text: ' files' },
      { type: 'delta', itemId: 'last', text: 'Done' },
    ],
    reply: 'Checking filesDone',
  },
  {
    agent: 'opencode',
    settings: { model: 'opencode/big-pickle', permission: 'ask' },
    options: { modelId: 'opencode/big-pickle', modeId: null },
    messages: [
      { sessionUpdate: 'agent_message_chunk', messageId: 'first', content: { type: 'text', text: 'Checking' } },
      { sessionUpdate: 'agent_message_chunk', messageId: 'first', content: { type: 'text', text: ' files' } },
      { sessionUpdate: 'agent_message_chunk', messageId: 'last', content: { type: 'text', text: 'Done' } },
    ],
    reply: 'Checking filesDone',
  },
  {
    agent: 'agy',
    settings: { permission: 'cautious' },
    options: { modeId: 'default' },
    messages: [
      { sessionUpdate: 'agent_message_chunk', messageId: 'first', content: { type: 'text', text: 'Checking' } },
      { sessionUpdate: 'agent_message_chunk', messageId: 'first', content: { type: 'text', text: ' files' } },
      { sessionUpdate: 'agent_message_chunk', messageId: 'last', content: { type: 'text', text: 'Done' } },
    ],
    reply: 'Checking filesDone',
  },  {
    agent: 'hermes',
    settings: { permission: 'cautious' },
    options: { modeId: 'default' },
    messages: [
      { sessionUpdate: 'agent_message_chunk', messageId: 'first', content: { type: 'text', text: 'Checking' } },
      { sessionUpdate: 'agent_message_chunk', messageId: 'first', content: { type: 'text', text: ' files' } },
      { sessionUpdate: 'agent_message_chunk', messageId: 'last', content: { type: 'text', text: 'Done' } },
    ],
    reply: 'Checking filesDone',
  },
  {
    // Cursor sends no message ids, so the tool call is what splits the reply.
    agent: 'cursor',
    settings: { model: 'big', effort: 'low', permission: 'bypass' },
    options: {
      modelId: null,
      modeId: 'agent',
      configOptions: [['model', 'big'], ['effort', 'low']],
    },
    messages: [
      { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Checking' } },
      { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: ' files' } },
      { sessionUpdate: 'tool_call', title: 'ls' },
      { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Done' } },
    ],
    reply: 'Checking filesDone',
  },
];

for (const { agent, settings, options, messages, reply } of cases) {
  test(`${agent} runs with scoped settings, streams segments, and resumes the saved session`, async () => {
    const workdir = '/tmp/runner-work';
    const sessionKey = `${workdir}\0${agent}\0review`;
    const otherKey = `${workdir}\0${agent}`;
    sessions[sessionKey] = { id: 'previous-session' };
    sessions[otherKey] = { id: 'main-session' };
    const calls = [];
    const controller = new AbortController();
    pools[agent].send = async (call) => {
      calls.push(call);
      for (const message of messages) call.onMessage(message);
      return {
        result: { subtype: 'success', result: 'Done' },
        sessionId: 'next-session',
        stderr: '',
      };
    };

    for (const prompt of ['Review this', 'Continue']) {
      const events = [];
      const result = await runAgent(agent, prompt, (event) => events.push(event), {
        workdir, settings, sessionKey, signal: controller.signal,
      });
      assert.equal(result, reply);
      const call = calls.at(-1);
      assert.equal(call.key, sessionKey);
      assert.equal(call.cwd, workdir);
      assert.equal(call.prompt, prompt);
      assert.equal(call.signal, controller.signal);
      for (const [key, value] of Object.entries(options)) {
        assert.deepEqual(call[key], value, key);
      }
      assert.deepEqual(events.filter((event) => event.type !== 'progress'), [
        { type: 'delta', text: 'Checking' },
        { type: 'delta', text: ' files' },
        { type: 'segment' },
        { type: 'delta', text: 'Done' },
      ]);
      assert.deepEqual(sessions[sessionKey], { id: 'next-session' });
      assert.deepEqual(sessions[otherKey], { id: 'main-session' });
    }
    assert.deepEqual(calls.map((call) => call.resumeId), ['previous-session', 'next-session']);
  });

  test(`${agent} reports cancellation and login failures as typed errors`, async () => {
    const options = { workdir: '/tmp/runner-errors', settings, sessionKey: `errors\0${agent}` };
    pools[agent].send = async () => {
      throw Object.assign(new Error('cancelled'), { code: 'AGENT_CANCELLED' });
    };
    await assert.rejects(runAgent(agent, 'hello', () => {}, options), (err) => {
      assert.ok(err instanceof AgentCancelledError);
      assert.equal(err.code, 'AGENT_CANCELLED');
      return true;
    });
    pools[agent].send = async () => {
      throw new Error('not logged in');
    };
    await assert.rejects(runAgent(agent, 'hello', () => {}, options), (err) => {
      assert.ok(err instanceof AgentAuthError);
      assert.equal(err.code, 'NOT_LOGGED_IN');
      assert.equal(err.agent, agent);
      return true;
    });
    assert.equal(sessions[options.sessionKey], undefined);
  });
}

test('lists cursor between codex and opencode', () => {
  assert.deepEqual(
    agents.listAgents().map((agent) => agent.key),
    ['claude', 'codex', 'cursor', 'opencode', 'agy', 'hermes'],
  );
});

test('each Cursor model choice runs in a process of its own', async () => {
  pools.cursor.send = async (call) => {
    call.onMessage({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'ok' } });
    return { result: { stopReason: 'end_turn' }, sessionId: 'next', stderr: '' };
  };
  const run = (key, settings) =>
    runAgent('cursor', 'hi', () => {}, { workdir: '/tmp/w', settings, sessionKey: key });
  const sentFrom = cursorSentVia.length;
  await run('choice-a', { model: 'default' });
  await run('choice-b', { model: 'big', effort: 'low' });
  await run('choice-c', { model: 'default' });
  // A scope whose choice changes leaves its old process before the new one runs.
  await run('choice-a', { model: 'big', effort: 'low' });
  const [auto, big, autoAgain, moved] = cursorSentVia.slice(sentFrom);
  assert.notEqual(auto, big);
  assert.equal(autoAgain, auto, 'scopes that share a choice share a process');
  assert.equal(moved, big);
  assert.ok(auto.forgotten.includes('choice-a'));
  assert.equal(big.forgotten.includes('choice-a'), false);
  for (const { options } of [auto, big]) {
    assert.equal(options.authMethod, 'cursor_login');
    assert.deepEqual(options.clientMeta, { parameterizedModelPicker: true });
  }
});

test('purging a cursor chat removes its session directory and nothing else', async () => {
  const sessionsDir = path.join(cursorConfigDir, 'acp-sessions');
  const id = '91986459-234b-4cb9-b192-9a89ee9ea780';
  fs.mkdirSync(path.join(sessionsDir, id), { recursive: true });
  fs.writeFileSync(path.join(sessionsDir, id, 'meta.json'), '{}');
  fs.mkdirSync(path.join(sessionsDir, 'keep'), { recursive: true });
  sessions.purged = { id };
  sessions.traversal = { id: '../keep' };
  await agents.purgeSession('purged', { agentKey: 'cursor', workdir: '/tmp/w' });
  await agents.purgeSession('traversal', { agentKey: 'cursor', workdir: '/tmp/w' });
  assert.equal(fs.existsSync(path.join(sessionsDir, id)), false);
  assert.equal(fs.existsSync(path.join(sessionsDir, 'keep')), true);
  assert.equal(sessions.purged, undefined);
});

test('an unknown agent is refused before using a pool', async () => {
  await assert.rejects(runAgent('missing', 'hello', () => {}, {
    workdir: '/tmp/runner-work', settings: {}, sessionKey: 'unknown',
  }), /Unknown agent: missing/);
});

test('Codex completed messages fill missing deltas without repeating streamed text', async () => {
  pools.codex.send = async (call) => {
    call.onMessage({ type: 'delta', itemId: 'first', text: 'Hello' });
    call.onMessage({ type: 'item', item: { type: 'agentMessage', id: 'first', text: 'Hello there' } });
    call.onMessage({ type: 'item', item: { type: 'agentMessage', id: 'first', text: 'Hello there' } });
    call.onMessage({
      type: 'item', item: { type: 'agentMessage', id: 'async', text: 'Follow-up', delivery: 'async' },
    });
    return { result: { stopReason: 'completed' }, sessionId: 'codex-full', stderr: '' };
  };
  const events = [];
  const result = await runAgent('codex', 'hi', (event) => events.push(event), {
    workdir: '/tmp/w', sessionKey: 'codex-full', settings: {},
  });
  assert.equal(result, 'Hello thereFollow-up');
  assert.deepEqual(events.filter((event) => event.type !== 'progress'), [
    { type: 'delta', text: 'Hello' },
    { type: 'delta', text: ' there' },
    { type: 'segment' },
    { type: 'delta', text: 'Follow-up' },
  ]);
});

test('Codex automatic replies open on text, replay events and stay separate from the user turn', async () => {
  let factory;
  pools.codex.send = async (call) => {
    factory = call.onBackgroundTurn;
    call.onMessage({ type: 'delta', itemId: 'user-reply', text: 'Initial reply' });
    return { result: { stopReason: 'completed' }, sessionId: 'codex-bg', stderr: '' };
  };
  const started = [];
  const foreground = [];
  await runAgent('codex', 'hi', (event) => foreground.push(event), {
    workdir: '/tmp/w', sessionKey: 'codex-bg', settings: {},
    onBackgroundTurn: (turn) => started.push(turn),
  });
  const tool = { type: 'item', item: { type: 'commandExecution', command: ['ls'] } };
  const silent = factory({ interrupt() {} });
  silent.onMessage(tool);
  silent.finish({ stopReason: 'completed' });
  assert.equal(started.length, 0);

  const background = factory({ interrupt() {} });
  background.onMessage(tool);
  background.onMessage({ type: 'delta', itemId: 'bg-first', text: 'Child done.' });
  background.onMessage({ type: 'item', item: { type: 'agentMessage', id: 'bg-first', text: 'Child done.' } });
  background.onMessage({ type: 'item', item: { type: 'agentMessage', id: 'bg-final', text: 'Ready.' } });
  assert.equal(started.length, 1);
  assert.deepEqual(started[0].progressLines, ['Codex continued on its own.']);
  const events = [];
  const done = started[0].run((event) => events.push(event));
  background.onMessage({ type: 'context', used: 4200, size: 258400 });
  background.finish({ stopReason: 'completed' });
  assert.equal(await done, 'Child done.Ready.');
  assert.deepEqual(events.filter((event) => event.type !== 'progress'), [
    { type: 'delta', text: 'Child done.' },
    { type: 'segment' },
    { type: 'delta', text: 'Ready.' },
    { type: 'context', used: 4200, size: 258400 },
  ]);
  assert.deepEqual(foreground.filter((event) => event.type === 'delta'), [
    { type: 'delta', text: 'Initial reply' },
  ]);
});

test('stopping an automatic Codex reply interrupts it and rejects its chat turn', async () => {
  let factory;
  pools.codex.send = async (call) => {
    factory = call.onBackgroundTurn;
    return { result: { stopReason: 'completed' }, sessionId: 'codex-stop', stderr: '' };
  };
  let started;
  await runAgent('codex', 'hi', () => {}, {
    workdir: '/tmp/w', sessionKey: 'codex-stop', settings: {},
    onBackgroundTurn: (turn) => { started = turn; },
  });
  let interrupted = 0;
  const background = factory({ interrupt: () => { interrupted += 1; } });
  background.onMessage({ type: 'delta', itemId: 'bg', text: 'Working' });
  const done = started.run(() => {});
  started.cancel();
  background.fail(Object.assign(new Error('cancelled'), { code: 'AGENT_CANCELLED' }));
  await assert.rejects(done, AgentCancelledError);
  assert.equal(interrupted, 1);
});

test('Antigravity approvals follow the selected tier', async () => {
  for (const permission of ['cautious', 'bypass']) {
    pools.agy.send = async (call) => {
      assert.equal(call.onPermission({ title: 'Write a file' }), permission === 'bypass');
      return { result: {}, sessionId: 'agy-permission', stderr: '' };
    };
    await runAgent('agy', 'hi', () => {}, {
      sessionKey: 'agy-permission', workdir: '/tmp/w', settings: { permission },
    });
  }
});

test('Antigravity emits context usage from trajectory metadata after a turn', async () => {
  agyContexts['agy-ctx-session'] = { used: 10428, size: 256000 };
  pools.agy.send = async (call) => {
    call.onMessage({
      sessionUpdate: 'agent_message_chunk',
      messageId: 'm1',
      content: { type: 'text', text: 'Hello' },
    });
    return { result: { stopReason: 'end_turn' }, sessionId: 'agy-ctx-session', stderr: '' };
  };
  const events = [];
  const reply = await runAgent('agy', 'hi', (event) => events.push(event), {
    sessionKey: 'agy-ctx',
    workdir: '/tmp/w',
    settings: { permission: 'cautious' },
  });
  assert.equal(reply, 'Hello');
  assert.deepEqual(
    events.filter((e) => e.type === 'context'),
    [{ type: 'context', used: 10428, size: 256000 }],
  );
});

test('Antigravity background turns open on text, include wakeup notices, and support cancellation', async () => {
  let factory;
  pools.agy.send = async (call) => {
    factory = call.onBackgroundTurn;
    call.onMessage({
      sessionUpdate: 'agent_message_chunk',
      messageId: 'm1',
      content: { type: 'text', text: 'Started timer' },
    });
    return { result: { stopReason: 'end_turn' }, sessionId: 'agy-bg', stderr: '' };
  };
  const started = [];
  await runAgent('agy', 'set timer', () => {}, {
    workdir: '/tmp/w',
    sessionKey: 'agy-bg',
    settings: { permission: 'bypass' },
    onBackgroundTurn: (turn) => started.push(turn),
  });

  // A tool-only background turn never reaches the chat history.
  const silent = factory({
    notices: [{ summary: 'Task id task-1 finished with result' }],
    interrupt() {},
  });
  silent.onMessage({ sessionUpdate: 'tool_call', title: 'run_command' });
  silent.finish({ stopReason: 'end_turn' });
  assert.equal(started.length, 0);

  // Once assistant text arrives, the background turn opens with its wakeup notice.
  let interrupted = 0;
  const active = factory({
    notices: [{ summary: 'Task id task-7 finished with result' }],
    interrupt: () => {
      interrupted += 1;
    },
  });
  active.onMessage({ sessionUpdate: 'tool_call', title: 'read_file' });
  active.onMessage({
    sessionUpdate: 'agent_message_chunk',
    messageId: 'step-5',
    content: { type: 'text', text: 'Timer ' },
  });
  active.onMessage({
    sessionUpdate: 'agent_message_chunk',
    messageId: 'step-5',
    content: { type: 'text', text: 'complete.' },
  });
  active.onMessage({
    sessionUpdate: 'agent_message_chunk',
    messageId: 'step-7',
    content: { type: 'text', text: 'All done.' },
  });
  assert.equal(started.length, 1);
  assert.deepEqual(started[0].progressLines, [
    'Background task: Task id task-7 finished with result',
  ]);
  const bgEvents = [];
  const done = started[0].run((event) => bgEvents.push(event));
  active.onMessage({ sessionUpdate: 'usage_update', used: 12000, size: 256000 });
  active.finish({ stopReason: 'end_turn' });
  assert.equal(await done, 'Timer complete.All done.');
  assert.deepEqual(
    bgEvents.filter((event) => event.type !== 'progress'),
    [
      { type: 'delta', text: 'Timer ' },
      { type: 'delta', text: 'complete.' },
      { type: 'segment' },
      { type: 'delta', text: 'All done.' },
      { type: 'context', used: 12000, size: 256000 },
    ],
  );

  // Stopping a background turn calls interrupt and rejects with AgentCancelledError.
  const stopped = factory({
    notices: [],
    interrupt: () => {
      interrupted += 1;
    },
  });
  stopped.onMessage({
    sessionUpdate: 'agent_message_chunk',
    messageId: 'step-9',
    content: { type: 'text', text: 'Partial' },
  });
  assert.equal(started.length, 2);
  assert.deepEqual(started[1].progressLines, [
    'Antigravity continued on its own.',
  ]);
  const stopPromise = started[1].run(() => {});
  started[1].cancel();
  stopped.fail(Object.assign(new Error('cancelled'), { code: 'AGENT_CANCELLED' }));
  await assert.rejects(stopPromise, AgentCancelledError);
  assert.equal(interrupted, 1);
});
