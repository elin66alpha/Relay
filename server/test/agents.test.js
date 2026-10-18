'use strict';

const assert = require('node:assert/strict');
const { test, beforeEach } = require('node:test');

process.env.RELAY_MODEL_DISCOVERY = '0';

const sessions = {};
const pools = { claude: {}, codex: {}, opencode: {}, hermes: {} };
// Replace factories before agents.js captures them. The session store is in
// memory because its production filename has no environment override.
const replacements = {
  '../lib/json-store': {
    createJsonStore: () => ({
      load: () => sessions,
      mutate: (fn) => fn(sessions),
    }),
  },
  '../lib/claude-session-pool': { createClaudeSessionPool: () => pools.claude },
  '../lib/codex-session-pool': { createCodexSessionPool: () => pools.codex },
  '../lib/acp-session-pool': {
    createAcpSessionPool: ({ agentKey }) => pools[agentKey],
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

test('an unknown agent is refused before using a pool', async () => {
  await assert.rejects(runAgent('missing', 'hello', () => {}, {
    workdir: '/tmp/runner-work', settings: {}, sessionKey: 'unknown',
  }), /Unknown agent: missing/);
});
