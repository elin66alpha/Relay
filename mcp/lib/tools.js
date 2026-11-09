'use strict';

const { randomUUID } = require('node:crypto');
const path = require('node:path');

const { runTerminal } = require('./terminal');

const DEFAULT_WAIT_SECONDS = 20;
const MAX_WAIT_SECONDS = 600;
const DEFAULT_MAX_CHARS = 8000;

function bounded(value, fallback, min, max) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, Math.floor(number)));
}

function required(args, key) {
  const value = String(args[key] === undefined ? '' : args[key]).trim();
  if (!value) throw new Error(`${key} is required`);
  return value;
}

function page(text, args, fallback = DEFAULT_MAX_CHARS) {
  const value = String(text || '');
  const offset = bounded(args.offset, 0, 0, value.length);
  const maxChars = bounded(args.maxChars, fallback, 200, 100000);
  const content = value.slice(offset, offset + maxChars);
  return {
    content,
    totalChars: value.length,
    ...(offset + content.length < value.length ? { truncated: true, nextOffset: offset + content.length } : {}),
  };
}

function messageSummary(message, maxChars) {
  const metadata = message.metadata || {};
  const text = String(message.content || '');
  return {
    id: message.id,
    role: message.role,
    agent: message.agent,
    createdAt: message.createdAt,
    ...(metadata.streaming ? { streaming: true } : {}),
    ...(metadata.cancelled ? { cancelled: true } : {}),
    ...(metadata.errorCode ? { errorCode: metadata.errorCode } : {}),
    content: text.slice(0, maxChars),
    ...(text.length > maxChars ? { truncated: true, totalChars: text.length } : {}),
  };
}

function turnStatus(message) {
  const metadata = message.metadata || {};
  if (metadata.streaming) return 'running';
  if (metadata.cancelled) return 'cancelled';
  if (metadata.errorCode) return 'error';
  return 'done';
}

// Splits a target file path with the backend's path flavour, which may differ
// from this machine's (a Windows backend driven from a Linux bot).
function splitPath(value) {
  const lib = /^[A-Za-z]:[\\/]|\\/.test(value) ? path.win32 : path.posix;
  const dir = lib.dirname(value);
  return { dir: dir === '.' ? '' : dir, name: lib.basename(value), absolute: lib.isAbsolute(value) };
}

const AGENT = {
  type: 'string',
  description: 'Agent key from relay_status (claude, codex, cursor, opencode, agy, hermes).',
};
const SESSION = {
  type: 'string',
  description: 'Chat session id from relay_sessions. Omit for the agent\'s active session.',
};
const WAIT = {
  type: 'integer',
  description: `Seconds to wait for the reply before returning status "running" (default ${DEFAULT_WAIT_SECONDS}, max ${MAX_WAIT_SECONDS}). The turn keeps running on the backend either way.`,
};
const OFFSET = { type: 'integer', description: 'Character offset for paging long text (default 0).' };
const MAX_CHARS = { type: 'integer', description: `Maximum characters returned (default ${DEFAULT_MAX_CHARS}).` };

function schema(properties, requiredKeys = []) {
  return { type: 'object', properties, required: requiredKeys, additionalProperties: false };
}

function createTools({ getClient, state, machineName }) {
  const relay = () => getClient();

  async function ensureWorkdir() {
    if (!state.workdir) state.workdir = (await relay().json('/api/workdir')).dir;
    return state.workdir;
  }

  async function activeSessionId(agent, workdir) {
    const sessions = await relay().json('/api/sessions', { query: { agent }, workdir });
    return sessions.activeSessionId;
  }

  async function soloTask({ requestId, agent, sessionId, workdir, ...args }) {
    const history = await relay().json('/api/history', { query: { agent, sessionId }, workdir });
    const message = history.messages.find((item) => item.id === `${requestId}:assistant`);
    if (!message) {
      return {
        status: 'not_found',
        requestId,
        hint: 'No reply for this requestId in this agent, session and workdir.',
      };
    }
    const metadata = message.metadata || {};
    const status = turnStatus(message);
    return {
      status,
      requestId,
      agent,
      sessionId: history.session && history.session.id,
      workdir: history.workdir,
      elapsedSeconds: Math.round(
        ((status === 'running' ? Date.now() : Date.parse(message.updatedAt || message.createdAt)) -
          Date.parse(message.createdAt)) / 1000,
      ),
      ...(status === 'running' ? { progress: (metadata.progressLines || []).slice(-8) } : {}),
      reply: page(message.content, args),
    };
  }

  async function swarmTask({ requestId, groupId, workdir, ...args }) {
    const history = await relay().json('/api/group/history', { query: { groupId }, workdir });
    const maxChars = bounded(args.maxChars, DEFAULT_MAX_CHARS, 200, 100000);
    const messages = history.messages.filter((item) => String(item.id).startsWith(requestId));
    if (!messages.length) return { status: 'not_found', requestId, groupId };
    return {
      status: history.runningRequestId === requestId ? 'running' : 'done',
      requestId,
      groupId,
      workdir: history.workdir,
      messages: messages.map((item) => messageSummary(item, maxChars)),
    };
  }

  const tools = [
    {
      name: 'relay_status',
      description: 'Backend status, this MCP\'s current workdir, and every agent with installed/authed/usable flags. Call first.',
      inputSchema: schema({}),
      async handler() {
        const [status, agents] = await Promise.all([
          relay().json('/api/status'),
          relay().json('/api/agents'),
        ]);
        return { machine: machineName, workdir: await ensureWorkdir(), status, ...agents };
      },
    },
    {
      name: 'relay_agent_options',
      description: 'Selectable models, reasoning efforts, permission tiers and fast mode for one agent, plus its CLI version.',
      inputSchema: schema({ agent: AGENT }, ['agent']),
      async handler(args) {
        const agent = required(args, 'agent');
        const [options, version] = await Promise.all([
          relay().json('/api/agent-options', { query: { agent } }),
          relay().json('/api/agent-version', { query: { agent } }),
        ]);
        return { ...options, version: version.version };
      },
    },
    {
      name: 'relay_agent_settings',
      description: 'Get or set the model, effort, permission and fast selection of one chat session. Ids come from relay_agent_options; only the groups you pass change.',
      inputSchema: schema({
        action: { type: 'string', enum: ['get', 'set'] },
        agent: AGENT,
        sessionId: SESSION,
        model: { type: 'string' },
        effort: { type: 'string' },
        permission: { type: 'string' },
        fast: { type: 'string' },
      }, ['action', 'agent']),
      async handler(args) {
        const agent = required(args, 'agent');
        if (args.action === 'get') {
          return relay().json('/api/agent-settings', { query: { agent, sessionId: args.sessionId } });
        }
        const body = { agent, sessionId: args.sessionId };
        for (const group of ['model', 'effort', 'permission', 'fast']) {
          if (typeof args[group] === 'string') body[group] = args[group];
        }
        return relay().json('/api/agent-settings', { method: 'POST', body });
      },
    },
    {
      name: 'relay_agent_update',
      description: 'Run the agent CLI\'s own updater on the backend host (can take minutes) and report the version before and after.',
      inputSchema: schema({ agent: AGENT }, ['agent']),
      handler: (args) => relay().json('/api/agent-update', { method: 'POST', body: { agent: required(args, 'agent') } }),
    },
    {
      name: 'relay_chat',
      description: 'Send a message to one agent in the current workdir. Returns the reply when it finishes within waitSeconds; otherwise status "running" with a requestId to poll with relay_task.',
      inputSchema: schema({
        agent: AGENT,
        prompt: { type: 'string' },
        sessionId: SESSION,
        waitSeconds: WAIT,
      }, ['agent', 'prompt']),
      async handler(args) {
        const agent = required(args, 'agent');
        const prompt = required(args, 'prompt');
        const workdir = await ensureWorkdir();
        const sessionId = String(args.sessionId || '').trim() || (await activeSessionId(agent, workdir));
        const requestId = randomUUID();
        let queued = false;
        const result = await relay().stream('/api/chat', { agent, prompt, sessionId, requestId }, {
          workdir,
          waitMs: bounded(args.waitSeconds, DEFAULT_WAIT_SECONDS, 1, MAX_WAIT_SECONDS) * 1000,
          terminal: ['agent_done', 'agent_cancelled', 'agent_error'],
          onEvent(event) {
            if (event.type === 'agent_queued') queued = true;
            else if (event.type !== 'ready') queued = false;
          },
        });
        const turn = { requestId, agent, sessionId, workdir };
        if (!result.done) {
          return { status: queued ? 'queued' : 'running', ...turn, hint: 'Poll relay_task with requestId, agent, sessionId and workdir.' };
        }
        if (result.type === 'agent_done') {
          return { status: 'done', ...turn, reply: page(result.payload.message && result.payload.message.content, args) };
        }
        if (result.type === 'agent_cancelled') return { status: 'cancelled', ...turn };
        return { status: 'error', ...turn, error: result.payload.error, code: result.payload.code };
      },
    },
    {
      name: 'relay_task',
      description: 'Status of a turn started by relay_chat (pass agent) or relay_swarm_chat (pass groupId): running/done/cancelled/error, recent progress lines, and the reply paged by offset/maxChars.',
      inputSchema: schema({
        requestId: { type: 'string' },
        agent: AGENT,
        sessionId: SESSION,
        groupId: { type: 'string' },
        workdir: { type: 'string', description: 'The workdir returned with the requestId (default: current).' },
        offset: OFFSET,
        maxChars: MAX_CHARS,
      }, ['requestId']),
      async handler(args) {
        const requestId = required(args, 'requestId');
        const workdir = String(args.workdir || '').trim() || (await ensureWorkdir());
        if (String(args.groupId || '').trim()) {
          return swarmTask({ ...args, requestId, groupId: args.groupId.trim(), workdir });
        }
        return soloTask({ ...args, requestId, agent: required(args, 'agent'), workdir });
      },
    },
    {
      name: 'relay_cancel',
      description: 'Stop a running turn (agent chat) or round (pass groupId for a swarm).',
      inputSchema: schema({
        requestId: { type: 'string' },
        groupId: { type: 'string' },
        workdir: { type: 'string', description: 'The workdir returned with the requestId (default: current).' },
      }, ['requestId']),
      async handler(args) {
        const requestId = required(args, 'requestId');
        const workdir = String(args.workdir || '').trim() || undefined;
        const route = String(args.groupId || '').trim() ? '/api/group/chat/cancel' : '/api/chat/cancel';
        return relay().json(route, { method: 'POST', body: { requestId }, workdir });
      },
    },
    {
      name: 'relay_history',
      description: 'Read a conversation: "get" returns the newest messages (limit, skip) or one message paged (messageId, offset, maxChars); "search" finds text across agents in the workdir; "export" returns the session as Markdown paged by offset/maxChars.',
      inputSchema: schema({
        action: { type: 'string', enum: ['get', 'search', 'export'] },
        agent: AGENT,
        sessionId: SESSION,
        query: { type: 'string', description: 'Search text (search).' },
        limit: { type: 'integer', description: 'Messages returned by get (default 20, max 100).' },
        skip: { type: 'integer', description: 'Newest messages to skip, for older pages (get).' },
        messageId: { type: 'string', description: 'Return just this message, paged (get).' },
        offset: OFFSET,
        maxChars: MAX_CHARS,
      }, ['action']),
      async handler(args) {
        if (args.action === 'search') {
          return relay().json('/api/history/search', { query: { q: required(args, 'query'), agent: args.agent } });
        }
        const agent = required(args, 'agent');
        if (args.action === 'export') {
          const exported = await relay().json('/api/history/export', { query: { agent, sessionId: args.sessionId } });
          return { fileName: exported.fileName, session: exported.session, markdown: page(exported.markdown, args) };
        }
        const history = await relay().json('/api/history', { query: { agent, sessionId: args.sessionId } });
        if (args.messageId) {
          const message = history.messages.find((item) => item.id === args.messageId);
          if (!message) throw new Error('message not found');
          return { ...messageSummary(message, Infinity), ...page(message.content, args) };
        }
        const limit = bounded(args.limit, 20, 1, 100);
        const skip = bounded(args.skip, 0, 0, history.messages.length);
        const end = history.messages.length - skip;
        const maxChars = bounded(args.maxChars, 2000, 200, 100000);
        return {
          agent: history.agent,
          workdir: history.workdir,
          session: history.session,
          contextWindow: history.contextWindow,
          total: history.messages.length,
          messages: history.messages.slice(Math.max(0, end - limit), end).map((item) => messageSummary(item, maxChars)),
        };
      },
    },
    {
      name: 'relay_sessions',
      description: 'Chat sessions of one agent in the current workdir (max 8, Main cannot be renamed or deleted): list, create, activate, rename, delete, or clear (wipe its history and CLI session).',
      inputSchema: schema({
        action: { type: 'string', enum: ['list', 'create', 'activate', 'rename', 'delete', 'clear'] },
        agent: AGENT,
        sessionId: { type: 'string' },
        name: { type: 'string', description: 'Session name (create, rename).' },
        copySettingsFrom: { type: 'string', description: 'Session whose model settings a new session copies (create, default Main).' },
      }, ['action', 'agent']),
      async handler(args) {
        const agent = required(args, 'agent');
        const post = (route, body) => relay().json(route, { method: 'POST', body: { agent, ...body } });
        switch (args.action) {
          case 'list':
            return relay().json('/api/sessions', { query: { agent } });
          case 'create':
            return post('/api/sessions', { name: args.name, copySettingsFrom: args.copySettingsFrom });
          case 'activate':
            return post('/api/sessions/active', { sessionId: required(args, 'sessionId') });
          case 'rename':
            return post('/api/sessions/rename', { sessionId: required(args, 'sessionId'), name: required(args, 'name') });
          case 'delete':
            return post('/api/sessions/delete', { sessionId: required(args, 'sessionId') });
          case 'clear':
            return post('/api/session/clear', { sessionId: required(args, 'sessionId') });
          default:
            throw new Error('unknown action');
        }
      },
    },
    {
      name: 'relay_workdir',
      description: 'The work directory agents run in for this MCP connection: get, set (switch; create makes it if missing), or recent. Other devices keep their own workdir.',
      inputSchema: schema({
        action: { type: 'string', enum: ['get', 'set', 'recent'] },
        path: { type: 'string', description: 'Absolute path on the backend host (set).' },
        create: { type: 'boolean', description: 'Create the directory when missing (set).' },
      }, ['action']),
      async handler(args) {
        if (args.action === 'recent') return relay().json('/api/workdirs/recent');
        if (args.action === 'set') {
          const result = await relay().json('/api/workdir', {
            method: 'POST',
            body: { path: required(args, 'path'), create: args.create === true },
          });
          state.workdir = result.dir;
          return result;
        }
        const result = await relay().json('/api/workdir');
        state.workdir = result.dir;
        return result;
      },
    },
    {
      name: 'relay_files',
      description: 'Backend filesystem: browse a directory (absolute path, default the workdir), mkdir, read a text file (paged), or write a text file. Paths without a leading / are relative to the workdir. Sensitive paths are refused by the backend.',
      inputSchema: schema({
        action: { type: 'string', enum: ['browse', 'mkdir', 'read', 'write'] },
        path: { type: 'string' },
        name: { type: 'string', description: 'New directory name inside path (mkdir).' },
        content: { type: 'string', description: 'File text (write). Replaces the file.' },
        showHidden: { type: 'boolean' },
        limit: { type: 'integer', description: 'Entries returned by browse (default 200).' },
        offset: OFFSET,
        maxChars: MAX_CHARS,
      }, ['action']),
      async handler(args) {
        if (args.action === 'browse') {
          const listing = await relay().json('/api/workdir/browse', {
            query: { path: args.path, showHidden: args.showHidden ? '1' : undefined },
          });
          const limit = bounded(args.limit, 200, 1, 2000);
          const entries = listing.entries || [];
          return { ...listing, entries: entries.slice(0, limit), totalEntries: entries.length };
        }
        if (args.action === 'mkdir') {
          return relay().json('/api/fs/mkdir', {
            method: 'POST',
            body: { path: required(args, 'path'), name: required(args, 'name') },
          });
        }
        const target = required(args, 'path');
        if (args.action === 'write') {
          if (typeof args.content !== 'string') throw new Error('content is required');
          const { dir, name, absolute } = splitPath(target);
          return relay().json('/api/fs/upload', {
            method: 'POST',
            query: { path: dir, name, mkdir: absolute ? undefined : '1' },
            raw: Buffer.from(args.content, 'utf8'),
          });
        }
        const file = await relay().bytes('/api/fs/download', { query: { path: target } });
        if (file.contentType.includes('zip')) throw new Error('path is a directory; use action "browse"');
        if (file.buffer.subarray(0, 8192).includes(0)) {
          return { path: target, binary: true, bytes: file.buffer.length, contentType: file.contentType };
        }
        return { path: target, ...page(file.buffer.toString('utf8'), args, 20000) };
      },
    },
    {
      name: 'relay_swarms',
      description: 'Swarms (multi-agent group chats) in the current workdir: list, create (name, members, optional workTree), members (replace members), delete, clear (reset transcript and member sessions), history (newest messages).',
      inputSchema: schema({
        action: { type: 'string', enum: ['list', 'create', 'members', 'delete', 'clear', 'history'] },
        groupId: { type: 'string' },
        name: { type: 'string' },
        members: { type: 'array', items: { type: 'string' }, description: 'Agent keys.' },
        workTree: { type: 'string', description: 'Directory the swarm runs in (create, default the workdir).' },
        limit: { type: 'integer', description: 'Messages returned by history (default 20).' },
        maxChars: MAX_CHARS,
      }, ['action']),
      async handler(args) {
        const post = (route, body) => relay().json(route, { method: 'POST', body });
        switch (args.action) {
          case 'list':
            return relay().json('/api/groups');
          case 'create':
            return post('/api/groups', { name: args.name, members: args.members, workdir: args.workTree });
          case 'members':
            return post('/api/groups/members', { groupId: required(args, 'groupId'), members: args.members });
          case 'delete':
            return post('/api/groups/delete', { groupId: required(args, 'groupId') });
          case 'clear':
            return post('/api/group/clear', { groupId: required(args, 'groupId') });
          case 'history': {
            const history = await relay().json('/api/group/history', { query: { groupId: required(args, 'groupId') } });
            const limit = bounded(args.limit, 20, 1, 100);
            const maxChars = bounded(args.maxChars, 2000, 200, 100000);
            return {
              group: history.group,
              runningRequestId: history.runningRequestId,
              total: history.messages.length,
              messages: history.messages.slice(-limit).map((item) => messageSummary(item, maxChars)),
            };
          }
          default:
            throw new Error('unknown action');
        }
      },
    },
    {
      name: 'relay_swarm_chat',
      description: 'Send a message to a swarm; @mentions decide which members answer. Returns the round\'s replies when it ends within waitSeconds, otherwise status "running" with a requestId for relay_task (with groupId).',
      inputSchema: schema({
        groupId: { type: 'string' },
        prompt: { type: 'string' },
        waitSeconds: WAIT,
        maxChars: MAX_CHARS,
      }, ['groupId', 'prompt']),
      async handler(args) {
        const groupId = required(args, 'groupId');
        const workdir = await ensureWorkdir();
        const requestId = randomUUID();
        const result = await relay().stream('/api/group/chat', { groupId, prompt: required(args, 'prompt'), requestId }, {
          workdir,
          waitMs: bounded(args.waitSeconds, DEFAULT_WAIT_SECONDS, 1, MAX_WAIT_SECONDS) * 1000,
          terminal: ['group_done'],
        });
        if (!result.done) {
          return { status: 'running', requestId, groupId, workdir, hint: 'Poll relay_task with requestId, groupId and workdir.' };
        }
        return swarmTask({ requestId, groupId, workdir, maxChars: args.maxChars });
      },
    },
    {
      name: 'relay_usage',
      description: 'Subscription quota and usage for every agent that reports it (or one source).',
      inputSchema: schema({ source: { type: 'string', description: 'Optional single source key.' } }),
      handler: (args) => relay().json('/api/usage', { query: { source: args.source } }),
    },
    {
      name: 'relay_quota_schedules',
      description: 'Messages scheduled to send when a Claude Code or Codex quota window resets: list, create, cancel.',
      inputSchema: schema({
        action: { type: 'string', enum: ['list', 'create', 'cancel'] },
        sourceKey: { type: 'string', enum: ['claude', 'codex'], description: 'Quota whose reset triggers the message (create).' },
        agent: AGENT,
        sessionId: SESSION,
        prompt: { type: 'string' },
        targetResetsAt: { type: 'string', description: 'Reset time from relay_usage (create).' },
        replaceExisting: { type: 'boolean' },
        id: { type: 'string', description: 'Schedule id (cancel).' },
      }, ['action']),
      async handler(args) {
        if (args.action === 'list') return relay().json('/api/quota-schedules');
        if (args.action === 'cancel') {
          return relay().json('/api/quota-schedules/cancel', { method: 'POST', body: { id: required(args, 'id') } });
        }
        return relay().json('/api/quota-schedules', {
          method: 'POST',
          body: {
            sourceKey: required(args, 'sourceKey'),
            agent: required(args, 'agent'),
            sessionId: args.sessionId,
            prompt: args.prompt,
            targetResetsAt: args.targetResetsAt,
            replaceExisting: args.replaceExisting === true,
          },
        });
      },
    },
    {
      name: 'relay_machine',
      description: 'Backend host hardware, disks and temperatures (info) or the full diagnostics report (diagnostics).',
      inputSchema: schema({ action: { type: 'string', enum: ['info', 'diagnostics'] } }, ['action']),
      handler: (args) => relay().json(args.action === 'diagnostics' ? '/api/diagnostics' : '/api/machine'),
    },
    {
      name: 'relay_terminal',
      description: 'Shell on the backend host (this credential\'s own persistent terminal). Types input (Enter appended unless enter is false) and returns the new output once it goes quiet; without input returns the recent screen.',
      inputSchema: schema({
        input: { type: 'string' },
        enter: { type: 'boolean', description: 'Append Enter to input (default true).' },
        waitSeconds: { type: 'integer', description: 'Longest wait for output (default 5, max 60).' },
        maxChars: MAX_CHARS,
      }),
      async handler(args) {
        const input = typeof args.input === 'string' ? args.input : '';
        const data = input && args.enter !== false && !/[\r\n]$/.test(input) ? `${input}\r` : input;
        const result = await runTerminal(relay(), {
          input: data,
          waitMs: bounded(args.waitSeconds, 5, 1, 60) * 1000,
        });
        const text = data ? result.output : `${result.replay}${result.output}`;
        const maxChars = bounded(args.maxChars, DEFAULT_MAX_CHARS, 200, 100000);
        return {
          output: text.slice(-maxChars),
          ...(text.length > maxChars ? { truncated: true } : {}),
          ...(result.ended && result.ended !== 'closed' ? { ended: result.ended } : {}),
        };
      },
    },
  ];
  return tools;
}

module.exports = { createTools, splitPath };
