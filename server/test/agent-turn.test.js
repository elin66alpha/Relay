'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  createChatResponder,
  createNoopResponder,
  runAgentTurn,
} = require('../lib/agent-turn');

const agent = { key: 'claude', label: 'Claude' };
const session = { id: 'default', name: 'Main' };

function reqWithAccept(accept) {
  return {
    get(name) {
      return String(name || '').toLowerCase() === 'accept' ? accept : '';
    },
  };
}

function fakeResponse() {
  return {
    destroyed: false,
    writableEnded: false,
    statusCode: 200,
    headers: null,
    writes: [],
    jsonBody: null,
    writeHead(statusCode, headers) {
      this.statusCode = statusCode;
      this.headers = headers;
    },
    write(chunk) {
      this.writes.push(String(chunk));
    },
    end() {
      this.writableEnded = true;
    },
    status(statusCode) {
      this.statusCode = statusCode;
      return this;
    },
    json(body) {
      this.jsonBody = body;
      this.writableEnded = true;
      return this;
    },
  };
}

function parseSse(writes) {
  return writes
    .join('')
    .trim()
    .split(/\n\n+/)
    .filter(Boolean)
    .map((packet) => {
      const lines = packet.split('\n');
      const event = lines
        .find((line) => line.startsWith('event: '))
        .slice('event: '.length);
      const data = JSON.parse(
        lines.find((line) => line.startsWith('data: ')).slice('data: '.length),
      );
      return { event, data };
    });
}

function makeHarness(runAgentImpl, options = {}) {
  const broadcasts = [];
  const calls = [];
  const histories = new Map();
  const touched = [];
  const runningScopes = options.runningScopes || new Set();
  const scopeChains = options.scopeChains || new Map();
  const settings = options.settings || { permission: 'bypass' };

  const listFor = (scopeKey) => {
    if (!histories.has(scopeKey)) histories.set(scopeKey, []);
    return histories.get(scopeKey);
  };

  return {
    broadcasts,
    calls,
    histories,
    touched,
    runningScopes,
    scopeChains,
    dependencies: {
      broadcastScope(type, payload) {
        broadcasts.push({ type, payload: { ...payload } });
      },
      enqueueScope(scopeKey, taskFn) {
        calls.push({ type: 'enqueue', scopeKey });
        return taskFn();
      },
      getSettings(agentKey, contextKey) {
        calls.push({ type: 'settings', agentKey, contextKey });
        return settings;
      },
      runningScopes,
      runAgent(agentKey, prompt, onEvent, runOptions) {
        calls.push({ type: 'runAgent', agentKey, prompt, runOptions });
        return runAgentImpl(onEvent, runOptions);
      },
      scopeChains,
      touchChatSession(contextKey, sessionId) {
        touched.push({ contextKey, sessionId });
      },
      updateHistoryMessage(scopeKey, messageId, updater) {
        const list = listFor(scopeKey);
        const index = list.findIndex((message) => message.id === messageId);
        if (index === -1) return false;
        list[index] = updater(list[index]);
        return true;
      },
      upsertHistoryMessage(scopeKey, message) {
        const list = listFor(scopeKey);
        const index = list.findIndex((item) => item.id === message.id);
        if (index === -1) list.push(message);
        else list[index] = { ...list[index], ...message };
      },
    },
  };
}

function turnOptions(overrides = {}) {
  const abortController = new AbortController();
  return {
    agent,
    contextKey: 'context',
    deviceId: 'device-1234',
    prompt: 'hello',
    requestId: 'req-1',
    runState: {
      cancelled: false,
      cancelEventSent: false,
    },
    scopeKey: 'scope',
    session,
    signal: abortController.signal,
    workdir: '/repo',
    ...overrides,
  };
}

test('SSE responder preserves direct event order while scope events keep start/queued/done', async () => {
  const response = fakeResponse();
  const scopeChains = new Map([['scope', Promise.resolve()]]);
  const harness = makeHarness(
    async (onEvent) => {
      onEvent({ type: 'progress', line: 'thinking' });
      onEvent({ type: 'delta', text: 'hi' });
      return 'hi';
    },
    { scopeChains },
  );
  const responder = createChatResponder({
    req: reqWithAccept('text/event-stream'),
    res: response,
  });

  await runAgentTurn(turnOptions({ responder, dependencies: harness.dependencies }));

  assert.deepEqual(
    parseSse(response.writes).map((event) => event.event),
    ['ready', 'agent_queued', 'agent_progress', 'agent_delta', 'agent_done'],
  );
  assert.deepEqual(
    harness.broadcasts.map((event) => event.type),
    ['agent_start', 'agent_queued', 'agent_done'],
  );
  assert.equal(harness.runningScopes.size, 0);
});

test('JSON responder returns the final reply and broadcasts progress and delta', async () => {
  const response = fakeResponse();
  let notified = null;
  const harness = makeHarness(async (onEvent) => {
    onEvent({ type: 'progress', line: 'working' });
    onEvent({ type: 'delta', text: 'done' });
    return 'done';
  });
  const responder = createChatResponder({
    req: reqWithAccept('application/json'),
    res: response,
  });

  await runAgentTurn(turnOptions({
    responder,
    dependencies: harness.dependencies,
    notifyTaskCompletion(payload) {
      notified = payload;
    },
  }));

  assert.equal(response.statusCode, 200);
  assert.equal(response.jsonBody.message.content, 'done');
  assert.equal(notified.content, 'done');
  assert.deepEqual(
    harness.broadcasts.map((event) => event.type),
    ['agent_start', 'agent_progress', 'agent_delta', 'agent_done'],
  );
  assert.equal(response.writes.length, 0);
});

test('cancelled queued turns do not run the agent and return the preserved cancel response', async () => {
  const response = fakeResponse();
  const harness = makeHarness(async () => {
    throw new Error('agent should not run');
  });
  const responder = createChatResponder({
    req: reqWithAccept('application/json'),
    res: response,
  });

  await runAgentTurn(turnOptions({
    dependencies: harness.dependencies,
    responder,
    runState: {
      cancelled: true,
      cancelEventSent: false,
    },
  }));

  assert.equal(
    harness.calls.some((call) => call.type === 'runAgent'),
    false,
  );
  assert.equal(response.statusCode, 499);
  assert.deepEqual(response.jsonBody, {
    error: 'request cancelled',
    code: 'AGENT_CANCELLED',
  });
  assert.deepEqual(
    harness.broadcasts.map((event) => event.type),
    ['agent_start', 'agent_cancelled'],
  );
  assert.equal(harness.runningScopes.size, 0);
});

test('generic agent errors finalize history, broadcast agent_error, and return JSON 500', async () => {
  const response = fakeResponse();
  const error = new Error('boom');
  error.code = 'BOOM';
  const harness = makeHarness(async () => {
    throw error;
  });
  const responder = createChatResponder({
    req: reqWithAccept('application/json'),
    res: response,
  });

  await runAgentTurn(turnOptions({ responder, dependencies: harness.dependencies }));

  assert.equal(response.statusCode, 500);
  assert.deepEqual(response.jsonBody, { error: 'boom' });
  assert.deepEqual(
    harness.broadcasts.map((event) => event.type),
    ['agent_start', 'agent_error'],
  );
  const messages = harness.histories.get('scope');
  assert.equal(messages[1].content, 'boom');
  assert.equal(messages[1].metadata.streaming, false);
  assert.equal(messages[1].metadata.errorCode, 'BOOM');
});

test('no-op responder broadcasts scheduled progress and does not require task notification', async () => {
  const harness = makeHarness(async (onEvent) => {
    onEvent({ type: 'progress', line: 'quota resumed' });
    onEvent({ type: 'delta', text: ' scheduled ' });
    return ' scheduled done ';
  });

  await runAgentTurn(turnOptions({
    dependencies: harness.dependencies,
    finalizeContent({ content, streamedText }) {
      return String(content || streamedText || '').trim();
    },
    historyMetadata: {
      scheduledQuotaMessageId: 'schedule-1',
      quotaSourceKey: 'claude',
    },
    initialProgressLines: ['Scheduled after quota reset.'],
    responder: createNoopResponder(),
  }));

  assert.deepEqual(
    harness.broadcasts.map((event) => event.type),
    ['agent_start', 'agent_progress', 'agent_delta', 'agent_done'],
  );
  const messages = harness.histories.get('scope');
  assert.deepEqual(messages[1].metadata.progressLines, []);
  assert.equal(messages[1].content, 'scheduled done');
});
