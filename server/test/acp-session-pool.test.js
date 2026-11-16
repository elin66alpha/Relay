'use strict';

const { test, after } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { createAcpSessionPool } = require('../lib/acp-session-pool');

const AGENT = path.join(__dirname, 'fixtures', 'fake-acp-agent.js');

// A failing assertion skips the test's own cleanup, and a live agent process
// keeps the runner from exiting — which hides the failure behind a hang.
const opened = [];
after(async () => {
  for (const cleanup of opened) await cleanup();
});

// Each pool gets its own state file, so the assertions below read exactly what
// this test's agent process saw.
function makePool(options = {}) {
  const statePath = path.join(
    fs.mkdtempSync(path.join(os.tmpdir(), 'relay-acp-')),
    'state.log',
  );
  fs.writeFileSync(statePath, '');
  const childEnv = { FAKE_ACP_STATE: statePath, ...(options.agentEnv || {}) };
  const pool = createAcpSessionPool({
    agentKey: 'fake',
    env: {},
    command: () => ({
      cmd: process.execPath,
      args: [AGENT],
      // The fixture reads its flags from the environment it inherits.
    }),
    ...options,
  });
  // The pool spawns with process.env, so the flags have to live there. They are
  // restored when the pool shuts down.
  const previous = {};
  for (const [key, value] of Object.entries(childEnv)) {
    previous[key] = process.env[key];
    process.env[key] = value;
  }
  const done = async () => {
    await pool.shutdown();
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  };
  opened.push(done);
  return {
    pool,
    state: () =>
      fs
        .readFileSync(statePath, 'utf8')
        .split('\n')
        .filter(Boolean),
    done,
  };
}

function send(pool, key, prompt, extra = {}) {
  return pool.send({
    key,
    prompt,
    cwd: '/w',
    onMessage: () => {},
    ...extra,
  });
}

function textOf(updates) {
  return updates
    .filter((u) => u.sessionUpdate === 'agent_message_chunk')
    .map((u) => u.content.text)
    .join('');
}

// Wait for a condition the agent process reports asynchronously.
async function waitFor(check, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return true;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return false;
}

test('a second turn reuses the live session instead of opening another', async () => {
  const { pool, state, done } = makePool();
  const updates = [];
  const first = await send(pool, 'a', 'one', {
    onMessage: (u) => updates.push(u),
  });
  const second = await send(pool, 'a', 'two');
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  assert.equal(state().filter((l) => l.startsWith('new ')).length, 1);
  assert.equal(first.sessionId, second.sessionId);
  assert.equal(textOf(updates), 'echo:one');
  assert.equal(second.result.stopReason, 'end_turn');
  await done();
});

test('several scopes share one agent process', async () => {
  // This is the whole point of ACP over the Claude SDK: opencode costs ~360MB
  // to boot, and that is paid once rather than once per chat.
  const { pool, state, done } = makePool();
  const a = await send(pool, 'a', 'one', { cwd: '/w1' });
  const b = await send(pool, 'b', 'one', { cwd: '/w2' });
  assert.notEqual(a.sessionId, b.sessionId, 'independent sessions');
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  // cwd is per session, so two work trees still share the process.
  assert.ok(state().includes(`new ${a.sessionId} /w1`));
  assert.ok(state().includes(`new ${b.sessionId} /w2`));
  assert.equal(pool.stats().live, 2);
  await done();
});

test('message listener failures warn once per process and leave it usable', async (t) => {
  const warn = t.mock.method(console, 'warn', () => {});
  const { pool, state, done } = makePool();
  for (const key of ['a', 'b']) {
    let delivered = false;
    const { result } = await send(pool, key, 'one', {
      onMessage() {
        delivered = true;
        throw new Error('listener failed');
      },
    });
    assert.equal(delivered, true);
    assert.equal(result.stopReason, 'end_turn');
  }
  const updates = [];
  await send(pool, 'a', 'recovered', { onMessage: (u) => updates.push(u) });
  assert.equal(textOf(updates), 'echo:recovered');
  assert.equal(state().filter((line) => line.startsWith('spawn ')).length, 1);
  assert.equal(warn.mock.calls.length, 1);
  await done();
});

test('a cold start loads the stored session id', async () => {
  const { pool, state, done } = makePool();
  const result = await send(pool, 'a', 'one', { resumeId: 'stored-id' });
  assert.ok(state().includes('load stored-id /w'));
  assert.equal(result.sessionId, 'stored-id', 'keeps the caller session');
  assert.equal(result.startedNew, false);
  await done();
});

test('an unloadable stored session falls back to a new one and says so', async () => {
  const { pool, state, done } = makePool({ agentEnv: { FAKE_ACP_NO_LOAD: '1' } });
  const result = await send(pool, 'a', 'one', { resumeId: 'gone' });
  assert.notEqual(result.sessionId, 'gone');
  assert.equal(result.startedNew, true, 'the caller can tell the user');
  assert.equal(result.result.stopReason, 'end_turn');
  assert.ok(state().some((l) => l.startsWith('new ')));
  await done();
});

test('the model is applied over the protocol, once per session', async () => {
  const { pool, state, done } = makePool();
  await send(pool, 'a', 'one', { modelId: 'prov/model-x' });
  await send(pool, 'a', 'two', { modelId: 'prov/model-x' });
  const models = state().filter((l) => l.startsWith('model '));
  assert.equal(models.length, 1, 'unchanged settings do not re-set the model');
  assert.ok(models[0].endsWith('prov/model-x'));

  // A changed model switches live — no restart, unlike the Claude pool.
  await send(pool, 'a', 'three', { modelId: 'prov/model-y' });
  assert.equal(state().filter((l) => l.startsWith('model ')).length, 2);
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  assert.equal(state().filter((l) => l.startsWith('new ')).length, 1);
  await done();
});

test('the permission mode is applied like the model, and only on change', async () => {
  const { pool, state, done } = makePool();
  await send(pool, 'a', 'one', { modeId: 'dont_ask' });
  await send(pool, 'a', 'two', { modeId: 'dont_ask' });
  assert.equal(state().filter((l) => l.startsWith('mode ')).length, 1);
  await send(pool, 'a', 'three', { modeId: 'default' });
  const modes = state().filter((l) => l.startsWith('mode '));
  assert.equal(modes.length, 2);
  assert.ok(modes[1].endsWith('default'));
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  await done();
});

test('an agent without session/close still drops evicted sessions', async () => {
  // Hermes advertises no close capability: the pool must not send one, and the
  // session still leaves the pool so the cap is honoured.
  const { pool, state, done } = makePool({
    maxSessions: 1,
    agentEnv: { FAKE_ACP_NO_CLOSE: '1' },
  });
  await send(pool, 'a', 'one');
  await send(pool, 'b', 'one');
  assert.equal(pool.stats().live, 1);
  assert.equal(state().filter((l) => l.startsWith('close ')).length, 0);
  assert.deepEqual(pool.stats().keys, ['b']);
  await done();
});

test('the session cap evicts the least recently used idle session', async () => {
  const { pool, state, done } = makePool({ maxSessions: 2 });
  const a = await send(pool, 'a', 'one');
  await send(pool, 'b', 'one');
  assert.equal(pool.stats().live, 2);
  await send(pool, 'c', 'one');
  assert.equal(pool.stats().live, 2, 'never exceeds the cap');
  assert.ok(
    state().includes(`close ${a.sessionId}`),
    'the oldest idle session was closed on the agent too',
  );
  await done();
});

test('a turn blocked on the cap runs once another turn finishes', async () => {
  // Group chats summon several members at once, so more concurrent turns than
  // session slots is a normal state, not an error.
  const { pool, state, done } = makePool({ maxSessions: 1 });
  const controller = new AbortController();
  const busy = send(pool, 'a', 'hang', { signal: controller.signal });
  await waitFor(() => state().some((l) => l.endsWith('hang')));

  let blockedDone = false;
  const blocked = send(pool, 'b', 'queued').then((value) => {
    blockedDone = true;
    return value;
  });
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(blockedDone, false, 'waits while the only slot is busy');
  assert.equal(pool.stats().waiting, 1);

  // Freeing the slot is what wakes the waiter — the finished turn's session is
  // evictable again.
  controller.abort();
  await assert.rejects(busy, (err) => err.code === 'AGENT_CANCELLED');
  const result = await blocked;
  assert.equal(result.result.stopReason, 'end_turn');
  assert.equal(pool.stats().live, 1, 'still within the cap');
  await done();
});

test('cancelling a turn interrupts it and leaves the session usable', async () => {
  const { pool, state, done } = makePool();
  const controller = new AbortController();
  const pending = send(pool, 'a', 'hang', { signal: controller.signal });
  await waitFor(() => state().some((l) => l.endsWith('hang')));
  controller.abort();
  await assert.rejects(pending, (err) => err.code === 'AGENT_CANCELLED');
  assert.ok(state().some((l) => l.startsWith('cancel ')), 'cancel, not kill');

  // The session survives: the next turn lands on the same one.
  const next = await send(pool, 'a', 'after');
  assert.equal(state().filter((l) => l.startsWith('new ')).length, 1);
  assert.equal(next.result.stopReason, 'end_turn');
  await done();
});

test('an already-aborted signal rejects without prompting', async () => {
  const { pool, state, done } = makePool();
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    send(pool, 'a', 'never', { signal: controller.signal }),
    (err) => err.code === 'AGENT_CANCELLED',
  );
  assert.equal(state().filter((l) => l.startsWith('prompt ')).length, 0);
  await done();
});

test('permission requests are answered by the caller policy', async () => {
  const { pool, state, done } = makePool();
  const updates = [];
  await send(pool, 'a', 'perm', {
    onMessage: (u) => updates.push(u),
    // The runner answers yes or no; picking the matching option is the
    // driver's job, so the policy never touches protocol vocabulary.
    onPermission: () => true,
  });
  assert.ok(state().includes('permission yes'));
  assert.equal(textOf(updates), 'permission:yes');

  // No policy at all must not hang the agent: it gets an explicit answer.
  await send(pool, 'b', 'perm');
  assert.ok(state().includes('permission no'), 'refused, not left hanging');
  await done();
});

test('an idle session is closed, and the process goes with the last one', async () => {
  const { pool, state, done } = makePool({ idleMs: 40 });
  const first = await send(pool, 'a', 'one');
  assert.equal(pool.stats().live, 1);
  assert.equal(pool.stats().connected, true);
  await waitFor(() => pool.stats().live === 0);
  assert.equal(pool.stats().live, 0, 'evicted once idle');
  assert.ok(state().includes(`close ${first.sessionId}`));
  // The process exists only to host sessions.
  assert.ok(await waitFor(() => pool.stats().connected === false));

  // The conversation is unaffected: the next turn cold-starts and loads.
  const second = await send(pool, 'a', 'two', { resumeId: first.sessionId });
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 2);
  assert.equal(second.sessionId, first.sessionId);
  await done();
});

test('a warm session that dies before output is retried cold', async () => {
  const { pool, state, done } = makePool();
  const first = await send(pool, 'a', 'one');
  const second = await send(pool, 'a', 'die-quiet', {
    resumeId: first.sessionId,
  });
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 2);
  assert.equal(second.result.stopReason, 'end_turn');
  await done();
});

test('a warm session that dies mid-reply is not silently re-run', async () => {
  // Retrying would replay text the user already saw.
  const { pool, state, done } = makePool();
  await send(pool, 'a', 'one');
  await assert.rejects(
    send(pool, 'a', 'die'),
    (err) => err.code === 'AGENT_SESSION_LOST' && err.emitted === true,
  );
  assert.equal(state().filter((l) => l.startsWith('spawn ')).length, 1);
  await done();
});

test('every update in a turn reaches the caller, result excluded', async () => {
  const { pool, done } = makePool();
  const updates = [];
  await send(pool, 'a', 'two', { onMessage: (u) => updates.push(u) });
  assert.deepEqual(
    updates.map((u) => u.messageId),
    ['first', 'second'],
    'both assistant messages, so the runner can split them into segments',
  );
  await done();
});

test('forget without purge drops the session but keeps the transcript', async () => {
  const deleted = [];
  const { pool, state, done } = makePool({
    deleteCommand: (sessionId) => {
      deleted.push(sessionId);
      return { cmd: process.execPath, args: ['-e', ''] };
    },
  });
  const first = await send(pool, 'a', 'one');
  await pool.forget('a');
  assert.ok(state().includes(`close ${first.sessionId}`));
  assert.deepEqual(deleted, []);
  assert.equal(pool.stats().live, 0);
  await done();
});

test('forget with purge runs the delete command for the session', async () => {
  const deleted = [];
  const { pool, done } = makePool({
    deleteCommand: (sessionId) => {
      deleted.push(sessionId);
      return { cmd: process.execPath, args: ['-e', ''] };
    },
  });
  await send(pool, 'a', 'one');
  const purged = await pool.forget('a', { purge: true, sessionId: 'sess-x' });
  assert.equal(purged, true, 'the CLI reported success');
  assert.deepEqual(deleted, ['sess-x']);
  await done();
});

test('shutdown closes every session and kills the process', async () => {
  const { pool, state, done } = makePool();
  await send(pool, 'a', 'one');
  await send(pool, 'b', 'one');
  const pid = Number(
    state()
      .find((line) => line.startsWith('spawn '))
      .split(' ')[1],
  );
  await pool.shutdown();
  assert.equal(pool.stats().live, 0);
  assert.equal(pool.stats().connected, false);
  // A restart must not leave the agent behind holding memory.
  const gone = await waitFor(() => {
    try {
      process.kill(pid, 0);
      return false;
    } catch (_err) {
      return true;
    }
  });
  assert.ok(gone, 'the agent process is really gone');
  await done();
});

test('an auth method is sent once, before the session opens', async () => {
  const { pool, state, done } = makePool({ authMethod: 'cursor_login' });
  await send(pool, 'a', 'one');
  const lines = state();
  const authAt = lines.findIndex((line) => line === 'auth cursor_login');
  const newAt = lines.findIndex((line) => line.startsWith('new '));
  assert.ok(authAt >= 0 && authAt < newAt);
  await send(pool, 'a', 'two');
  assert.equal(state().filter((line) => line.startsWith('auth ')).length, 1);
  await done();
});

test('a cursor question is skipped instead of answered', async () => {
  const { pool, state, done } = makePool({ skipQuestions: true });
  const result = await send(pool, 'a', 'ask');
  assert.ok(state().includes('question skipped'));
  assert.equal(result.result.stopReason, 'end_turn');
  await done();
});

test('config options are applied in order, once per session', async () => {
  const { pool, state, done } = makePool({ clientMeta: { picker: true } });
  const configOptions = [['model', 'big'], ['effort', 'low']];
  const first = await send(pool, 'a', 'one', { configOptions });
  await send(pool, 'a', 'two', { configOptions });
  const config = state().filter((line) => line.startsWith('config '));
  assert.deepEqual(config, [
    `config ${first.sessionId} model=big`,
    `config ${first.sessionId} effort=low`,
  ]);
  assert.ok(state().includes('meta {"picker":true}'));
  await done();
});

test('listModels asks for the catalog without opening a session', async () => {
  const { pool, state, done } = makePool({ modelsMethod: 'cursor/list_available_models' });
  const models = await pool.callDriver('listModels');
  assert.deepEqual(models.map((model) => model.value), ['default', 'big']);
  assert.ok(state().includes('list models'));
  assert.equal(state().some((line) => line.startsWith('new ')), false);
  await done();
});

test('a missing binary fails the turn instead of the server', async () => {
  const pool = createAcpSessionPool({
    agentKey: 'fake',
    env: {},
    command: () => null,
  });
  await assert.rejects(send(pool, 'a', 'one'), /not installed/);
  await pool.shutdown();
});

test('trajectory watcher streams background turns, answers permissions, and filters ACP replay on the next turn', async () => {
  const steps = [
    { type: 'CORTEX_STEP_TYPE_USER_INPUT', status: 'CORTEX_STEP_STATUS_DONE' },
    {
      type: 'CORTEX_STEP_TYPE_PLANNER_RESPONSE',
      status: 'CORTEX_STEP_STATUS_DONE',
      plannerResponse: { response: 'echo:one' },
    },
  ];
  let cascadeStatus = 'CASCADE_RUN_STATUS_IDLE';
  const interactions = [];
  const cancellations = [];

  const { pool, done } = makePool({
    trajectory: {
      pollMs: 15,
      readTrajectory: async () => ({
        port: 43123,
        body: {
          status: cascadeStatus,
          trajectory: {
            trajectoryId: 'traj-bg',
            steps: steps.map((step) => structuredClone(step)),
          },
        },
      }),
      answerInteraction: async (port, sessionId, interaction, approve) => {
        interactions.push({ port, sessionId, interaction, approve });
        steps[interaction.stepIndex].status = 'CORTEX_STEP_STATUS_DONE';
      },
      cancelInvocation: async (port, sessionId) => {
        cancellations.push({ port, sessionId });
      },
      contextFromTrajectory: () => ({ used: 14500, size: 256000 }),
    },
  });

  const bgTurns = [];
  await send(pool, 'a', 'one', {
    onPermission: () => true,
    onBackgroundTurn: ({ notices, interrupt }) => {
      const updates = [];
      let finished = false;
      const turn = {
        notices,
        interrupt,
        updates,
         isFinished: () => finished,
      };
      bgTurns.push(turn);
      return {
        onMessage: (u) => updates.push(u),
        finish: () => {
          finished = true;
        },
        fail: () => {
          finished = true;
        },
      };
    },
  });

  // Append a background wakeup, a tool call + waiting interaction, and streamed text.
  steps.push(
    {
      type: 'CORTEX_STEP_TYPE_SYSTEM_MESSAGE',
      status: 'CORTEX_STEP_STATUS_DONE',
      systemMessage: {
        message:
          'Task id "/home/pc/.gemini/antigravity/brain/x/task-7" finished with result:\n<background_task_notification>',
        priority: 'MESSAGE_PRIORITY_HIGH',
      },
    },
    {
      type: 'CORTEX_STEP_TYPE_PLANNER_RESPONSE',
      status: 'CORTEX_STEP_STATUS_RUNNING',
      plannerResponse: {
        messageId: 'bg-msg-1',
        response: 'Background ',
        toolCalls: [{ id: 'bg-tc-1', name: 'run_command' }],
      },
    },
    {
      type: 'CORTEX_STEP_TYPE_RUN_COMMAND',
      status: 'CORTEX_STEP_STATUS_WAITING',
      requestedInteraction: {
        runCommand: { commandLine: 'echo ok' },
      },
    },
  );
  cascadeStatus = 'CASCADE_RUN_STATUS_RUNNING';

  assert.ok(await waitFor(() => interactions.length === 1));
  assert.equal(interactions[0].approve, true);
  assert.equal(bgTurns.length, 1);
  assert.deepEqual(bgTurns[0].notices, [
    { summary: 'Task id task-7 finished with result' },
  ]);

  // Complete the planner response and settle the cascade back to IDLE.
  steps[3].status = 'CORTEX_STEP_STATUS_DONE';
  steps[3].plannerResponse.response = 'Background reply.';
  cascadeStatus = 'CASCADE_RUN_STATUS_IDLE';

  assert.ok(await waitFor(() => bgTurns[0].isFinished()));
  assert.equal(textOf(bgTurns[0].updates), 'Background reply.');
  assert.ok(
    bgTurns[0].updates.some(
      (u) =>
        u.sessionUpdate === 'tool_call' &&
        u.toolCallId === 'bg-tc-1' &&
        u.title === 'run_command',
    ),
  );
  assert.ok(
    bgTurns[0].updates.some(
      (u) => u.sessionUpdate === 'usage_update' && u.used === 14500,
    ),
  );

  // On the next user turn, Antigravity's ACP server replays the background tool call
  // and full planner response text from its stale stepsSeen index; the driver drops
  // those duplicates and delivers only the new turn's output.
  const nextUpdates = [];
  await send(pool, 'a', 'replay-bg', {
    onMessage: (u) => nextUpdates.push(u),
  });
  assert.equal(textOf(nextUpdates), 'echo:replay-bg');
  assert.equal(
    nextUpdates.some((u) => u.toolCallId === 'bg-tc-1'),
    false,
    'replayed background tool call was filtered out',
  );
  await done();
});

for (const cancel of [false, true]) {
  test(`a user turn ${cancel ? 'can be cancelled while waiting for' : 'waits for'} background work started during settings`, async (t) => {
    const steps = [];
    let background;
    let nextCallbackUsed = false;
    const gateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-acp-model-'));
    const gatePath = path.join(gateDir, 'ready');
    t.after(() => fs.rmSync(gateDir, { recursive: true, force: true }));
    const { pool, state, done } = makePool({
      agentEnv: { FAKE_ACP_MODEL_GATE: gatePath },
      trajectory: {
        pollMs: 10,
        readTrajectory: async () => ({ port: 43123, body: { trajectory: { steps } } }),
      },
    });
    await send(pool, 'a', 'one', {
      onBackgroundTurn: () => {
        background = { updates: [], finished: false };
        return {
          onMessage: (u) => background.updates.push(u),
          finish: () => { background.finished = true; },
          fail: () => { background.finished = true; },
        };
      },
    });
    const controller = new AbortController();
    const pending = send(pool, 'a', 'after-settings', {
      modelId: 'delayed-model',
      signal: controller.signal,
      onBackgroundTurn: () => { nextCallbackUsed = true; },
    });
    assert.ok(await waitFor(() => state().some((line) => line.endsWith(' delayed-model'))));
    steps.push({
      status: 'CORTEX_STEP_STATUS_RUNNING',
      plannerResponse: { response: 'Background ' },
    });
    assert.ok(await waitFor(() => background));
    fs.writeFileSync(gatePath, '');
    assert.ok(await waitFor(() => state().some((line) => line.startsWith('model-applied '))));
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(state().some((line) => line.endsWith(' after-settings')), false);
    if (cancel) {
      controller.abort();
      await assert.rejects(pending, (err) => err.code === 'AGENT_CANCELLED');
      assert.equal(state().some((line) => line.endsWith(' after-settings')), false);
    }
    steps[0].status = 'CORTEX_STEP_STATUS_DONE';
    steps[0].plannerResponse.response = 'Background reply.';
    if (!cancel) await pending;
    assert.ok(await waitFor(() => background.finished));
    assert.equal(textOf(background.updates), 'Background reply.');
    assert.equal(nextCallbackUsed, false, 'background keeps the previous turn callbacks');
    await done();
  });
}

test('cancelled background polling stops after an in-flight interaction answer', async () => {
  const steps = [];
  const updates = [];
  let interrupt;
  let finished = false;
  let answered = 0;
  let release;
  const answer = new Promise((resolve) => { release = resolve; });
  const { pool, done } = makePool({
    trajectory: {
      pollMs: 10,
      readTrajectory: async () => ({ port: 43123, body: { trajectory: { steps } } }),
      answerInteraction: async () => { answered += 1; await answer; },
    },
  });
  await send(pool, 'a', 'one', {
    onBackgroundTurn: (handle) => {
      interrupt = handle.interrupt;
      return {
        onMessage: (u) => updates.push(u),
        fail: () => { finished = true; },
      };
    },
  });
  const waiting = {
    status: 'CORTEX_STEP_STATUS_WAITING',
    requestedInteraction: { runCommand: { commandLine: 'echo ok' } },
  };
  steps.push(waiting, { plannerResponse: { response: 'late text' } }, waiting);
  assert.ok(await waitFor(() => answered === 1));
  interrupt();
  assert.ok(await waitFor(() => finished));
  release();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(answered, 1, 'does not answer another interaction after cancellation');
  assert.equal(textOf(updates), '', 'does not dispatch later steps after cancellation');
  await done();
});

test('a failed user prompt restores trajectory monitoring', async () => {
  const steps = [];
  let polls = 0;
  let background = false;
  const { pool, done } = makePool({
    trajectory: {
      pollMs: 10,
      readTrajectory: async () => {
        polls += 1;
        return { port: 43123, body: { trajectory: { steps } } };
      },
    },
  });
  await send(pool, 'a', 'one');
  await assert.rejects(send(pool, 'a', 'fail-prompt', {
    onBackgroundTurn: () => { background = true; },
  }), /prompt failed/);
  const previousPolls = polls;
  steps.push({ plannerResponse: { response: 'Background reply.' } });
  assert.ok(await waitFor(() => polls > previousPolls && background));
  await done();
});

test('trajectory discovery backs off after the language server cannot be found', async (t) => {
  let polls = 0;
  let pollStarted;
  let releasePoll;
  const started = new Promise((resolve) => { pollStarted = resolve; });
  const stalled = new Promise((resolve) => { releasePoll = resolve; });
  const { pool, done } = makePool({
    trajectory: {
      pollMs: 10,
      readTrajectory: async () => {
        polls += 1;
        if (polls === 2) { pollStarted(); await stalled; }
        return null;
      },
    },
  });
  await send(pool, 'a', 'one');
  await started;
  // Keep agent transport real; control only the watcher's subsequent timers.
  t.mock.timers.enable({ apis: ['setTimeout'] });
  releasePoll();
  await new Promise((resolve) => setImmediate(resolve));
  const before = polls;
  t.mock.timers.tick(4999);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(polls, before);
  t.mock.timers.tick(1);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(polls, before + 1);
  t.mock.timers.reset();
  await done();
});
