'use strict';

const assert = require('node:assert/strict');
const { test, before, after } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const express = require('express');

// Isolate the on-disk state for groups + history before requiring the modules.
const scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-group-route-'));
process.env.RELAY_GROUPS_FILE = path.join(scratchDir, 'groups.json');
process.env.RELAY_HISTORY_FILE = path.join(scratchDir, 'history.json');
// Two agent-driven waves after the human's, so the chain and its cap are both
// observable without running a long conversation.
process.env.RELAY_SWARM_MAX_HOPS = '2';

const history = require('../lib/history');
const { sessionContextKeyFor, scopeKeyFor } = require('../lib/chat-sessions');
const { runAgentTurn } = require('../lib/agent-turn');
const { normalizeSettings } = require('../lib/agent-options');
const groups = require('../lib/groups');
const createGroupRouter = require('../routes/group');

const WORKDIR = '/tmp/group-int';
const AGENTS = {
  claude: { key: 'claude', label: 'Claude Code', run: () => {} },
  codex: { key: 'codex', label: 'Codex', run: () => {} },
};

// Calls into the fake CLI runner, so the test can assert the per-member session
// key and the delta-built prompt each member actually received.
const runCalls = [];
// Events broadcast on the shared stream, so the test can assert the round's
// lifecycle signals (group_message, group_done) reach other devices.
const sentEvents = [];
// Per-agent reply text, so a test can make one member @mention another. Empty
// means the default "reply from <agent>", which mentions nobody.
const scriptedReplies = new Map();
// Per-agent promises a turn waits on, so a test can hold a round open.
const heldReplies = new Map();
// Per-agent progress line a turn reports before replying.
const scriptedProgress = new Map();
// Task notifications the round sent.
const notified = [];
const purgedCalls = [];
let validateWorkdirOverride = null;

function buildContext() {
  const runningScopes = new Set();
  const scopeChains = new Map();

  // The shared dependencies the real runAgentTurn needs; the route overrides
  // runAgent (member session key) and broadcastScope (groupId tag) on top.
  const agentTurnDependencies = () => ({
    broadcastScope: () => {},
    enqueueScope: (_key, fn) => fn(),
    getSettings: () => ({}),
    runningScopes,
    scopeChains,
    touchChatSession: () => {},
    updateHistoryMessage: history.updateHistoryMessage,
    upsertHistoryMessage: history.upsertHistoryMessage,
    async runAgent(agentKey, prompt, onEvent, opts) {
      runCalls.push({
        agentKey,
        prompt,
        sessionKey: opts.sessionKey,
        workdir: opts.workdir,
        settings: opts.settings,
      });
      const reply = scriptedReplies.get(agentKey) || `reply from ${agentKey}`;
      if (scriptedProgress.has(agentKey)) {
        onEvent({ type: 'progress', line: scriptedProgress.get(agentKey) });
      }
      await heldReplies.get(agentKey);
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
    purgeSession: async (sessionKey, opts) => {
      purgedCalls.push({ sessionKey, ...opts });
      return true;
    },
    finalizeStaleStreamingHistory: history.finalizeStaleStreamingHistory,
    getAgent: (key) => AGENTS[key] || null,
    normalizeDeviceId: () => '',
    notifyTaskCompletion: (payload) => notified.push(payload),
    readHistory: history.readHistory,
    requestWorkdir: (req) => req.get('x-workdir') || WORKDIR,
    runAgentTurn,
    runningScopes,
    scopeChains,
    scopeKeyFor,
    sendEvent: (type, payload) => sentEvents.push({ type, payload }),
    sendWorkdirError: (res, err) => res.status(400).json({ error: err.message }),
    sessionContextKeyFor,
    upsertHistoryMessage: history.upsertHistoryMessage,
    // The real resolver canonicalizes + checks the path exists; the route only
    // needs the resolved dir, so echo it back for the test.
    validateWorkdir: (value, opts) =>
      validateWorkdirOverride ? validateWorkdirOverride(value, opts) : { dir: String(value), created: false },
  };
}

let server;
let base;

before(async () => {
  const app = express();
  app.use(express.json());
  app.use(createGroupRouter(buildContext()));
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  const { port } = server.address();
  base = `http://127.0.0.1:${port}`;
});

after(() => {
  if (server) server.close();
  fs.rmSync(scratchDir, { recursive: true, force: true });
});

function api(method, urlPath, body, workdir = WORKDIR) {
  return fetch(`${base}${urlPath}`, {
    method,
    headers: { 'Content-Type': 'application/json', 'X-Workdir': workdir },
    body: body ? JSON.stringify(body) : undefined,
  });
}

test('a round fans out to mentioned members in order with correct attribution', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'Builders',
    members: ['claude', 'codex'],
  })).json();
  const group = created.group;
  assert.ok(group.id);

  const round = await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: 'please @codex then @claude build the thing',
  })).json();
  assert.equal(round.ok, true);
  assert.deepEqual(
    round.turns.map((t) => t.agent),
    ['codex', 'claude'],
  );

  const histResp = await (await api('GET', `/api/group/history?groupId=${group.id}`)).json();
  const messages = histResp.messages;

  // Exactly one human message (recorded once per round, not per summoned agent).
  const humans = messages.filter((m) => m.role === 'user');
  assert.equal(humans.length, 1);
  assert.equal(humans[0].metadata.author, 'human');

  // Assistant messages attributed to each member, in summon order.
  const assistants = messages.filter((m) => m.role === 'assistant');
  assert.equal(assistants.length, 2);
  assert.equal(assistants[0].metadata.author, 'codex');
  assert.equal(assistants[0].metadata.summonedBy, 'human');
  assert.match(assistants[0].content, /reply from codex/);
  assert.equal(assistants[1].metadata.author, 'claude');
  assert.match(assistants[1].content, /reply from claude/);

  // The round announces itself on the shared stream so other devices stay in
  // sync: the human echo and a terminal group_done (which triggers their
  // reconcile reload), both tagged with this group's id.
  const roundEvents = sentEvents.filter((e) => e.payload.groupId === group.id);
  const types = roundEvents.map((e) => e.type);
  assert.ok(types.includes('group_message'), 'expected a group_message broadcast');
  assert.ok(types.includes('group_done'), 'expected a group_done broadcast');
});

test('each member resumes its own group session key, not the group transcript key', () => {
  const codexCall = runCalls.find((c) => c.agentKey === 'codex');
  const claudeCall = runCalls.find((c) => c.agentKey === 'claude');
  assert.ok(codexCall && claudeCall);
  // Member CLI session = `${workdir}\0${agent}\0${groupId}` — distinct per member,
  // and never the group transcript key `${workdir}\0group:${groupId}`.
  assert.match(codexCall.sessionKey, new RegExp(`^${WORKDIR}\\x00codex\\x00`));
  assert.match(claudeCall.sessionKey, new RegExp(`^${WORKDIR}\\x00claude\\x00`));
  assert.ok(!codexCall.sessionKey.includes('group:'));
});

test('same-message mentions run in order, each seeing earlier replies in the same wave', () => {
  const codexCall = runCalls.find((c) => c.agentKey === 'codex');
  const claudeCall = runCalls.find((c) => c.agentKey === 'claude');
  // Both see the human turn and are told it is their turn.
  assert.match(codexCall.prompt, /Human: please .*build the thing/);
  assert.match(claudeCall.prompt, /Human: please .*build the thing/);
  assert.match(codexCall.prompt, /your turn, Codex/);
  assert.match(claudeCall.prompt, /your turn, Claude Code/);
  // Codex ran first so it did not see Claude; Claude ran second so it sees Codex's reply.
  assert.ok(!codexCall.prompt.includes('reply from claude'));
  assert.match(claudeCall.prompt, /Codex: reply from codex/);
});

test('a member that already ran after a mentioning reply in the same wave is not re-summoned', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'No Stale Re-summon',
    members: ['claude', 'codex'],
  })).json();
  const group = created.group;
  // Codex runs first and mentions @claude; Claude runs second in the same wave,
  // already sees Codex's reply, and finishes without mentioning anyone.
  scriptedReplies.set('codex', 'hey @claude what do you think?');
  scriptedReplies.set('claude', 'looks good, we are done');

  const round = await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@codex and @claude check this',
  })).json();
  scriptedReplies.clear();

  assert.deepEqual(round.turns.map((t) => t.agent), ['codex', 'claude']);
});

test('a member @mentioned by another member takes the next turn', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'Relay Chain',
    members: ['claude', 'codex'],
  })).json();
  const group = created.group;
  scriptedReplies.set('claude', 'I mapped it out, @codex take the lexer');
  scriptedReplies.set('codex', 'lexer done, nothing else needed');
  const before = runCalls.length;

  const round = await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@claude start us off',
  })).json();
  scriptedReplies.clear();

  // The human summoned one member; its reply summoned the other.
  assert.deepEqual(
    round.turns.map((t) => t.agent),
    ['claude', 'codex'],
  );
  const codexCall = runCalls.slice(before).find((c) => c.agentKey === 'codex');
  assert.ok(codexCall);
  // The second wave snapshots again, so Codex is fed the reply that summoned it.
  assert.match(codexCall.prompt, /Claude Code: I mapped it out, @codex take the lexer/);
  // And it is told who else it can hand the floor to.
  assert.match(codexCall.prompt, /Other members of this swarm: Claude Code \(@claude\)/);

  const messages = (await (await api(
    'GET',
    `/api/group/history?groupId=${group.id}`,
  )).json()).messages;
  const assistants = messages.filter((m) => m.role === 'assistant');
  assert.equal(assistants.length, 2);
  assert.equal(assistants[0].metadata.summonedBy, 'human');
  // The transcript records which member summoned the follow-up turn.
  assert.equal(assistants[1].metadata.author, 'codex');
  assert.equal(assistants[1].metadata.summonedBy, 'claude');
});

test('two members mentioning each other stop at the hop cap', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'Relay Pingpong',
    members: ['claude', 'codex'],
  })).json();
  const group = created.group;
  // Each reply summons the other, forever, if nothing bounds the round.
  scriptedReplies.set('claude', 'over to you @codex');
  scriptedReplies.set('codex', 'back to you @claude');

  const round = await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@claude begin',
  })).json();
  scriptedReplies.clear();

  // RELAY_SWARM_MAX_HOPS=2: the human's wave plus two agent-driven ones.
  assert.deepEqual(
    round.turns.map((t) => t.agent),
    ['claude', 'codex', 'claude'],
  );
  // The last reply still named codex, which the round reports instead of
  // dropping silently.
  assert.deepEqual(round.unsummoned, ['codex']);
});

test('a round broadcasts members\' progress and notifies once, named after the swarm', async () => {
  const { group } = await (await api('POST', '/api/groups', {
    name: 'Notify Crew',
    members: ['claude', 'codex'],
  })).json();
  const notifiedBefore = notified.length;
  const eventsBefore = sentEvents.length;
  scriptedProgress.set('claude', 'Reading files');
  // A streaming request (relay-mcp) gets progress too, and other devices still do.
  const stream = await (await fetch(`${base}/api/group/chat`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
      'X-Workdir': WORKDIR,
    },
    body: JSON.stringify({ groupId: group.id, prompt: '@claude @codex check' }),
  })).text();
  scriptedProgress.clear();

  assert.match(stream, /event: agent_progress/);
  const progress = sentEvents
    .slice(eventsBefore)
    .filter((e) => e.type === 'group_agent_progress');
  assert.equal(progress.length, 1);
  assert.equal(progress[0].payload.groupId, group.id);
  assert.equal(progress[0].payload.agent.key, 'claude');
  assert.equal(progress[0].payload.line, 'Reading files');
  assert.ok(!sentEvents.slice(eventsBefore).some((e) => e.type === 'group_agent_delta'));
  assert.deepEqual(notified.slice(notifiedBefore), [{
    agent: { label: 'Notify Crew' },
    scopeWorkdir: WORKDIR,
    content: 'reply from codex',
  }]);
});

test('a member mentioning itself does not summon another turn', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'Relay Solo',
    members: ['claude', 'codex'],
  })).json();
  const group = created.group;
  scriptedReplies.set('claude', 'noting for myself, @claude follow up later');

  const round = await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@claude think out loud',
  })).json();
  scriptedReplies.clear();

  assert.deepEqual(
    round.turns.map((t) => t.agent),
    ['claude'],
  );
});

test('a later message still sees earlier replies, so cross-round stays collaborative', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'Relay Builders',
    members: ['claude', 'codex'],
  })).json();
  const group = created.group;

  // Round 1: only Codex speaks.
  await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@codex kick things off',
  })).json();

  // Round 2 (a separate message): Claude now sees Codex's earlier reply, because
  // its delta is snapshotted after round 1 was recorded.
  const before = runCalls.length;
  await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@claude build on that',
  })).json();
  const claudeCall = runCalls.slice(before).find((c) => c.agentKey === 'claude');
  assert.ok(claudeCall);
  assert.match(claudeCall.prompt, /Codex: reply from codex/);
});

test('a message naming no one goes to the last speaker, and is refused before anyone spoke', async () => {
  const { group } = await (await api('POST', '/api/groups', {
    name: 'Quiet',
    members: ['claude', 'codex'],
  })).json();
  const before = runCalls.length;

  const refused = await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: 'just thinking out loud, no summon here',
  });
  assert.equal(refused.status, 400);
  assert.equal((await refused.json()).code, 'GROUP_NO_MENTION');
  assert.equal(runCalls.length, before);
  const empty = await (await api('GET', `/api/group/history?groupId=${group.id}`)).json();
  assert.deepEqual(empty.messages, []);

  await api('POST', '/api/group/chat', { groupId: group.id, prompt: '@codex draft it' });
  const round = await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: 'continue',
  })).json();
  assert.deepEqual(round.turns.map((t) => t.agent), ['codex']);
});

test('a swarm runs in its chosen work tree with each member its configured settings', async () => {
  const workTree = '/tmp/group-int-tree';
  const claudeConfig = { permission: 'plan' };
  const created = await (await api('POST', '/api/groups', {
    name: 'Tree',
    members: ['claude'],
    workdir: workTree,
    configs: { claude: claudeConfig },
  })).json();
  const group = created.group;
  // The work tree and per-member config round-trip in the payload.
  assert.equal(group.workdir, workTree);
  assert.deepEqual(group.memberConfigs.claude, normalizeSettings('claude', claudeConfig));

  const before = runCalls.length;
  const round = await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@claude go',
  })).json();
  assert.equal(round.ok, true);

  const call = runCalls.slice(before).find((c) => c.agentKey === 'claude');
  assert.ok(call);
  // The member runs in the work tree, not the workspace, and with the swarm's
  // configured settings rather than its solo-chat defaults.
  assert.equal(call.workdir, workTree);
  assert.match(call.sessionKey, new RegExp(`^${workTree}\\x00claude\\x00`));
  assert.deepEqual(call.settings, normalizeSettings('claude', claudeConfig));
});

test('unknown group and empty members are rejected', async () => {
  const missing = await api('GET', '/api/group/history?groupId=does-not-exist');
  assert.equal(missing.status, 404);

  const noMembers = await api('POST', '/api/groups', { name: 'X', members: ['ghost'] });
  assert.equal(noMembers.status, 400);
});

test('a second message while a round runs is refused and history names the round', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'One At A Time',
    members: ['claude'],
  })).json();
  const group = created.group;
  let release;
  heldReplies.set('claude', new Promise((resolve) => { release = resolve; }));
  const historyOf = async () =>
    (await api('GET', `/api/group/history?groupId=${group.id}`)).json();

  const first = api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@claude take your time',
    requestId: 'round-held',
  });
  try {
    for (let i = 0; i < 400 && !runCalls.some((c) => c.prompt.includes('take your time')); i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    assert.equal((await historyOf()).runningRequestId, 'round-held');

    const busy = await api('POST', '/api/group/chat', {
      groupId: group.id,
      prompt: '@claude and another thing',
    });
    assert.equal(busy.status, 409);
    assert.equal((await busy.json()).code, 'GROUP_BUSY');
  } finally {
    release();
    heldReplies.clear();
  }
  assert.equal((await (await first).json()).turns[0].status, 'done');
  const settled = await historyOf();
  assert.equal(settled.runningRequestId, null);
  const reply = settled.messages.find((m) => m.role === 'assistant');
  assert.equal(reply.content, 'reply from claude');
  assert.equal(reply.metadata.cancelled, undefined);
  assert.equal(
    settled.messages.filter((m) => m.role === 'user').length,
    1,
    'the refused message is not recorded',
  );
});

test('default swarm name uses the lowest unused Swarm N', async () => {
  const first = await (await api('POST', '/api/groups', { members: ['claude'] })).json();
  const second = await (await api('POST', '/api/groups', { members: ['claude'] })).json();
  assert.equal(first.group.name, 'Swarm 1');
  assert.equal(second.group.name, 'Swarm 2');
  await api('POST', '/api/groups/delete', { groupId: first.group.id });
  const third = await (await api('POST', '/api/groups', { members: ['claude'] })).json();
  assert.equal(third.group.name, 'Swarm 1');
});

test('GET /api/groups lists swarms across workdirs and routes find them from any solo workdir', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'Cross Workdir',
    members: ['claude'],
  }, '/tmp/wd-alpha')).json();
  const group = created.group;
  const listed = await (await api('GET', '/api/groups', undefined, '/tmp/wd-beta')).json();
  assert.ok(listed.groups.some((g) => g.id === group.id));

  const eventsBefore = sentEvents.length;
  const round = await (await api('POST', '/api/group/chat', {
    groupId: group.id,
    prompt: '@claude hello from beta',
  }, '/tmp/wd-beta')).json();
  assert.equal(round.ok, true);
  assert.deepEqual(round.turns, [{ agent: 'claude', status: 'done' }]);
  const emitted = sentEvents.slice(eventsBefore).filter((e) => e.payload.groupId === group.id);
  assert.ok(emitted.some((e) => e.type === 'group_message'));
  assert.ok(emitted.some((e) => e.type === 'group_done'));
  assert.ok(emitted.every((e) => e.payload.scopeWorkdir === undefined));

  const hist = await (await api('GET', `/api/group/history?groupId=${group.id}`, undefined, '/tmp/wd-gamma')).json();
  assert.equal(hist.messages.length, 2);
});

test('POST /api/groups/workdir changes local work tree, moves transcript, purges sessions, and validates', async () => {
  const created = await (await api('POST', '/api/groups', {
    name: 'Move Tree',
    members: ['claude'],
    workdir: '/tmp/old-tree',
  })).json();
  const group = created.group;
  await api('POST', '/api/group/chat', { groupId: group.id, prompt: '@claude hi' });

  // Invalid workdir is rejected and leaves the swarm unchanged.
  validateWorkdirOverride = () => {
    throw new Error('workdir path does not exist');
  };
  const bad = await api('POST', '/api/groups/workdir', {
    groupId: group.id,
    workdir: '/tmp/missing-tree',
  });
  validateWorkdirOverride = null;
  assert.equal(bad.status, 400);

  const purgedBefore = purgedCalls.length;
  const moved = await (await api('POST', '/api/groups/workdir', {
    groupId: group.id,
    workdir: '/tmp/new-tree',
  })).json();
  assert.equal(moved.ok, true);
  assert.equal(moved.group.workdir, '/tmp/new-tree');
  assert.ok(purgedCalls.slice(purgedBefore).some((c) => c.workdir === '/tmp/old-tree' && c.agentKey === 'claude'));
  const hist = await (await api('GET', `/api/group/history?groupId=${group.id}`)).json();
  assert.equal(hist.messages.length, 2, 'transcript is preserved across workdir change');

  // Refused while a round is running (409 GROUP_BUSY).
  let release;
  heldReplies.set('claude', new Promise((resolve) => { release = resolve; }));
  const running = api('POST', '/api/group/chat', { groupId: group.id, prompt: '@claude hold' });
  try {
    for (let i = 0; i < 400 && !runCalls.some((c) => c.prompt.includes('hold')); i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    const busy = await api('POST', '/api/groups/workdir', {
      groupId: group.id,
      workdir: '/tmp/another-tree',
    });
    assert.equal(busy.status, 409);
    assert.equal((await busy.json()).code, 'GROUP_BUSY');
    // Its purged session holds nothing, so it is fed the earlier transcript.
    const held = runCalls.find((c) => c.prompt.includes('hold'));
    assert.match(held.prompt, /Human: @claude hi/);
  } finally {
    release();
    heldReplies.clear();
  }
  await running;
});

test('changing members without configs keeps each member\'s stored config', async () => {
  const { group } = await (await api('POST', '/api/groups', {
    name: 'Keep Configs',
    members: ['claude'],
    configs: { claude: { nickname: 'Architect', prompt: 'Design first.' } },
  })).json();
  const added = await (await api('POST', '/api/groups/members', {
    groupId: group.id,
    members: ['claude', 'codex'],
  })).json();
  const kept = added.groups.find((g) => g.id === group.id).memberConfigs.claude;
  assert.equal(kept.nickname, 'Architect');
  assert.equal(kept.prompt, 'Design first.');
  // A config that is sent still replaces the stored one.
  const cleared = await (await api('POST', '/api/groups/members', {
    groupId: group.id,
    members: ['claude', 'codex'],
    configs: { claude: { nickname: 'Builder' } },
  })).json();
  const replaced = cleared.groups.find((g) => g.id === group.id).memberConfigs.claude;
  assert.equal(replaced.nickname, 'Builder');
  assert.equal(replaced.prompt, undefined);
});
