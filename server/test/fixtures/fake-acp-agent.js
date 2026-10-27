'use strict';

// A stand-in ACP agent: speaks the real JSON-RPC-over-stdio protocol so the
// pool's transport, framing and process lifecycle are exercised for real.
// Behaviour is driven by magic prompts (`hang`, `die`, `perm`, `mem`) and by
// env flags, and every notable event is appended to FAKE_ACP_STATE so a test
// can assert what the agent actually saw.
const fs = require('fs');

const statePath = process.env.FAKE_ACP_STATE || '';
const noLoad = process.env.FAKE_ACP_NO_LOAD === '1';
const noClose = process.env.FAKE_ACP_NO_CLOSE === '1';

function record(line) {
  if (!statePath) return;
  try {
    fs.appendFileSync(statePath, `${line}\n`);
  } catch (_err) {
    // The test may have torn the scratch dir down already.
  }
}

function write(frame) {
  process.stdout.write(`${JSON.stringify(frame)}\n`);
}

const sessions = new Map();
let counter = 0;
const hanging = new Map();

record(`spawn ${process.pid}`);

function update(sessionId, payload) {
  write({
    jsonrpc: '2.0',
    method: 'session/update',
    params: { sessionId, update: payload },
  });
}

function finishPrompt(id, sessionId, text) {
  update(sessionId, {
    sessionUpdate: 'agent_message_chunk',
    messageId: `m${counter}`,
    content: { type: 'text', text },
  });
  write({ jsonrpc: '2.0', id, result: { stopReason: 'end_turn' } });
}

function handlePrompt(msg) {
  const { sessionId, prompt } = msg.params;
  const text = prompt.map((part) => part.text).join('');
  const session = sessions.get(sessionId);
  if (!session) {
    write({
      jsonrpc: '2.0',
      id: msg.id,
      error: { code: -32602, message: `unknown session ${sessionId}` },
    });
    return;
  }
  session.prompts.push(text);
  record(`prompt ${sessionId} ${text}`);

  if (text === 'hang') {
    hanging.set(sessionId, msg.id);
    return;
  }
  if (text === 'die') {
    update(sessionId, {
      sessionUpdate: 'agent_message_chunk',
      messageId: 'm-die',
      content: { type: 'text', text: 'partial' },
    });
    process.exit(3);
  }
  if (text === 'die-quiet') {
    // Dies once, so a retry on a fresh process can succeed — the pool's cold
    // fallback is only useful if the next attempt is allowed to work.
    let already;
    try {
      already = fs.readFileSync(statePath, 'utf8').includes('died');
    } catch (_err) {
      already = false;
    }
    if (!already) {
      record('died');
      process.exit(4);
    }
    finishPrompt(msg.id, sessionId, 'recovered');
    return;
  }
  if (text === 'ask') {
    const id = 2000 + counter++;
    write({
      jsonrpc: '2.0',
      id,
      method: 'cursor/ask_question',
      params: { toolCallId: 'q1', questions: [] },
    });
    session.pendingQuestion = { promptId: msg.id, sessionId };
    return;
  }
  if (text === 'perm') {
    // Ask, then report which option the client picked so the test can assert
    // the tier policy end to end.
    const id = 1000 + counter++;
    write({
      jsonrpc: '2.0',
      id,
      method: 'session/request_permission',
      params: {
        sessionId,
        toolCall: { toolCallId: 'tc1', title: 'write /tmp/x', kind: 'edit' },
        // "always" first, as Cursor lists it, so the test sees which kind the
        // client prefers rather than which comes first.
        options: [
          { optionId: 'always', name: 'Allow always', kind: 'allow_always' },
          { optionId: 'yes', name: 'Allow', kind: 'allow_once' },
          { optionId: 'no', name: 'Deny', kind: 'reject_once' },
        ],
      },
    });
    session.pendingPermission = { promptId: msg.id, sessionId };
    return;
  }
  if (text === 'mem') {
    finishPrompt(msg.id, sessionId, session.prompts.join(','));
    return;
  }
  if (text === 'two') {
    // Two assistant messages in one turn: the pool must forward both, and the
    // runner turns the messageId change into a segment boundary.
    update(sessionId, {
      sessionUpdate: 'agent_message_chunk',
      messageId: 'first',
      content: { type: 'text', text: 'one' },
    });
    update(sessionId, {
      sessionUpdate: 'agent_message_chunk',
      messageId: 'second',
      content: { type: 'text', text: 'two' },
    });
    write({ jsonrpc: '2.0', id: msg.id, result: { stopReason: 'end_turn' } });
    return;
  }
  update(sessionId, { sessionUpdate: 'tool_call', title: 'ls', kind: 'read' });
  finishPrompt(msg.id, sessionId, `echo:${text}`);
}

// The catalog `cursor/list_available_models` answers with.
const MODELS = [
  { value: 'default', name: 'Auto', configOptions: [] },
  {
    value: 'big',
    name: 'Big',
    configOptions: [
      {
        id: 'effort',
        category: 'thought_level',
        currentValue: 'high',
        options: [{ value: 'low', name: 'Low' }, { value: 'high', name: 'High' }],
      },
    ],
  },
];

function handle(msg) {
  if (msg.method === undefined && msg.id !== undefined) {
    // A reply to a question or permission request we just sent.
    for (const session of sessions.values()) {
      if (session.pendingQuestion) {
        const pending = session.pendingQuestion;
        session.pendingQuestion = null;
        const outcome = (msg.result && msg.result.outcome) || {};
        record(`question ${outcome.outcome || 'error'}`);
        finishPrompt(
          pending.promptId,
          pending.sessionId,
          `question:${outcome.outcome || 'error'}`,
        );
        return;
      }
      const pending = session.pendingPermission;
      if (!pending) continue;
      session.pendingPermission = null;
      const outcome = (msg.result && msg.result.outcome) || {};
      const picked =
        outcome.outcome === 'selected' ? outcome.optionId : outcome.outcome;
      record(`permission ${picked}`);
      finishPrompt(pending.promptId, pending.sessionId, `permission:${picked}`);
      return;
    }
    return;
  }

  const reply = (result) => write({ jsonrpc: '2.0', id: msg.id, result });
  const fail = (message) =>
    write({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message } });

  switch (msg.method) {
    case 'authenticate':
      record(`auth ${msg.params.methodId}`);
      reply({});
      return;
    case 'initialize':
      if (msg.params.clientCapabilities._meta) {
        record(`meta ${JSON.stringify(msg.params.clientCapabilities._meta)}`);
      }
      reply({
        protocolVersion: 1,
        agentInfo: { name: 'fake', version: '1' },
        agentCapabilities: {
          loadSession: !noLoad,
          sessionCapabilities: noClose ? {} : { close: {} },
        },
      });
      return;
    case 'session/new': {
      counter += 1;
      const sessionId = `sess-${process.pid}-${counter}`;
      sessions.set(sessionId, { prompts: [], cwd: msg.params.cwd });
      record(`new ${sessionId} ${msg.params.cwd}`);
      reply({ sessionId });
      return;
    }
    case 'session/load': {
      const { sessionId } = msg.params;
      if (noLoad) {
        record(`load-failed ${sessionId}`);
        fail('session not found');
        return;
      }
      sessions.set(sessionId, { prompts: [], cwd: msg.params.cwd });
      record(`load ${sessionId} ${msg.params.cwd}`);
      reply({});
      return;
    }
    case 'session/prompt':
      handlePrompt(msg);
      return;
    case 'session/cancel': {
      const { sessionId } = msg.params;
      record(`cancel ${sessionId}`);
      const promptId = hanging.get(sessionId);
      if (promptId !== undefined) {
        hanging.delete(sessionId);
        write({ jsonrpc: '2.0', id: promptId, result: { stopReason: 'cancelled' } });
      }
      return;
    }
    case 'session/set_model':
      record(`model ${msg.params.sessionId} ${msg.params.modelId}`);
      reply({});
      return;
    case 'session/set_config_option':
      record(`config ${msg.params.sessionId} ${msg.params.configId}=${msg.params.value}`);
      reply({});
      return;
    case 'cursor/list_available_models':
      record('list models');
      reply({ models: MODELS });
      return;
    case 'session/set_mode':
      record(`mode ${msg.params.sessionId} ${msg.params.modeId}`);
      reply({});
      return;
    case 'session/close':
      record(`close ${msg.params.sessionId}`);
      sessions.delete(msg.params.sessionId);
      reply({});
      return;
    default:
      fail(`unsupported method: ${msg.method}`);
  }
}

let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (!line) continue;
    try {
      handle(JSON.parse(line));
    } catch (_err) {
      // Malformed input is not this fixture's problem.
    }
  }
});
// Closing stdin is how the pool asks an agent to exit.
process.stdin.on('end', () => {
  record(`exit ${process.pid}`);
  process.exit(0);
});
