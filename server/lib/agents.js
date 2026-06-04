'use strict';

const { spawn } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { getDefaultWorkdir } = require('./workdir');
const { buildArgs } = require('./agent-options');

const TIMEOUT_MS = parseInt(
  process.env.AGENT_TIMEOUT_MS || String(60 * 60 * 1000),
  10,
);

// Persistent CLI sessions: each session key keeps one continuous conversation.
// Keys are scoped by workdir + agent + optional chat session id. clearSession
// lets the app start a fresh machine-side conversation after history is cleared.
const SESSION_FILE = path.join(__dirname, '..', 'agent-sessions.json');

class AgentCancelledError extends Error {
  constructor() {
    super('request cancelled');
    this.name = 'AgentCancelledError';
    this.code = 'AGENT_CANCELLED';
  }
}

// Raised when an agent CLI has no logged-in account / no usable API key, so the
// caller can surface a real "log in on the host" state instead of returning the
// raw CLI error as if it were the assistant's reply.
class AgentAuthError extends Error {
  constructor(agentKey) {
    super(`${agentKey} is not logged in`);
    this.name = 'AgentAuthError';
    this.code = 'NOT_LOGGED_IN';
    this.agent = agentKey;
  }
}

// Heuristic detection of "the CLI has no logged-in account / no API key". The
// CLIs expose no machine-readable signal for this, so we match the human
// messages they print. Kept deliberately auth-specific so it never swallows the
// separate "resumed session not found" messages, which are handled on their own.
const AUTH_ERROR_RE = new RegExp(
  [
    'not logged in',
    'not authenticated',
    'please log\\s?in',
    'please sign in',
    '(?:must|need to) log\\s?in',
    'run\\s+`?(?:claude|codex|agy|gemini)?\\s*login`?',
    '/login\\b',
    'login (?:required|expired)',
    'unauthorized',
    'authentication (?:failed|required|error)',
    'invalid api key',
    '(?:missing|no) api key',
  ].join('|'),
  'i',
);

function isAuthError(text) {
  return AUTH_ERROR_RE.test(String(text || ''));
}

function loadSessions() {
  try {
    return JSON.parse(fs.readFileSync(SESSION_FILE, 'utf-8'));
  } catch (_err) {
    return {};
  }
}

function saveSessions(sessions) {
  fs.writeFileSync(SESSION_FILE, JSON.stringify(sessions), { mode: 0o600 });
}

function getSession(sessionKey) {
  return loadSessions()[sessionKey] || null;
}

function setSession(sessionKey, value) {
  const sessions = loadSessions();
  sessions[sessionKey] = value;
  saveSessions(sessions);
}

function clearSession(sessionKey) {
  const sessions = loadSessions();
  if (!(sessionKey in sessions)) return false;
  delete sessions[sessionKey];
  saveSessions(sessions);
  return true;
}

function emit(onEvent, event) {
  if (typeof onEvent !== 'function' || !event) return;
  try {
    if (typeof event === 'string') {
      onEvent({ type: 'progress', line: event });
    } else {
      onEvent(event);
    }
  } catch (_err) {
    // Progress callbacks should not affect the running agent.
  }
}

function oneLine(value, max = 100) {
  const text = String(value).replace(/\s+/g, ' ').trim();
  return text.length > max ? `${text.slice(0, max - 1)}...` : text;
}

function fallback(stdout, stderr, code, label) {
  const merged = [String(stdout).trim(), String(stderr).trim()]
    .filter(Boolean)
    .join('\n');
  return merged || `(${label} exited with code ${code}, no output)`;
}

function makeDeltaEmitter(onEvent) {
  let streamed = '';
  return (value) => {
    const text = String(value || '');
    if (!text) return;

    let delta = text;
    if (streamed && text.startsWith(streamed)) {
      delta = text.slice(streamed.length);
    } else if (streamed && streamed.endsWith(text)) {
      delta = '';
    }

    if (!delta) return;
    streamed += delta;
    emit(onEvent, { type: 'delta', text: delta });
  };
}

function spawnStream({ cmd, args, cwd, label, onLine, finalize, signal }) {
  return new Promise((resolve, reject) => {
    if (signal && signal.aborted) {
      reject(new AgentCancelledError());
      return;
    }

    const proc = spawn(cmd, args, {
      cwd,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    let buffer = '';
    let finished = false;

    const cleanup = () => {
      clearTimeout(timer);
      if (signal) signal.removeEventListener('abort', cancel);
    };

    const cancel = () => {
      if (finished) return;
      finished = true;
      cleanup();
      proc.kill('SIGKILL');
      reject(new AgentCancelledError());
    };

    const timer = setTimeout(() => {
      if (finished) return;
      finished = true;
      cleanup();
      proc.kill('SIGKILL');
      resolve(
        `Timed out after ${Math.round(
          TIMEOUT_MS / 60000,
        )} minutes and was stopped. Split the task or simplify the prompt.`,
      );
    }, TIMEOUT_MS);

    if (signal) signal.addEventListener('abort', cancel, { once: true });

    proc.stdout.on('data', (chunk) => {
      const text = chunk.toString();
      stdout += text;
      if (!onLine) return;
      buffer += text;
      let index;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (line.trim()) {
          try {
            onLine(line);
          } catch (_err) {
            // Ignore malformed progress lines.
          }
        }
      }
    });

    proc.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });

    proc.on('error', (err) => {
      if (finished) return;
      finished = true;
      cleanup();
      resolve(`Unable to start ${label}: ${err.message}`);
    });

    proc.on('close', (code) => {
      if (finished) return;
      finished = true;
      cleanup();
      if (onLine && buffer.trim()) {
        try {
          onLine(buffer);
        } catch (_err) {
          // Ignore trailing malformed progress.
        }
      }
      try {
        resolve(finalize({ code, stdout, stderr }));
      } catch (err) {
        resolve(`${label} output parsing failed: ${err.message}`);
      }
    });
  });
}

function toolBrief(name, input) {
  const data = input || {};
  let detail = '';
  if (name === 'Bash') detail = data.command || '';
  else if (
    name === 'Read' ||
    name === 'Edit' ||
    name === 'Write' ||
    name === 'NotebookEdit'
  ) {
    detail = data.file_path || '';
  } else if (name === 'Grep' || name === 'Glob') {
    detail = data.pattern || data.glob || '';
  } else if (name === 'Task') {
    detail = data.description || '';
  } else if (name === 'WebFetch' || name === 'WebSearch') {
    detail = data.url || data.query || '';
  } else {
    detail = Object.keys(data).slice(0, 2).join(', ');
  }
  return `${name}${detail ? `: ${oneLine(detail, 80)}` : ''}`;
}

function runClaude(prompt, onEvent, sessionKey, signal, workdir, settings) {
  const cwd = workdir || getDefaultWorkdir();
  const prior = getSession(sessionKey);
  const resuming = !!(prior && prior.id);
  // Resume reuses the saved session ID; new conversations use our UUID as
  // --session-id until the CLI reports the canonical ID.
  let sessionId = resuming ? prior.id : crypto.randomUUID();
  let finalText = '';
  let isError = false;
  const emitDelta = makeDeltaEmitter(onEvent);

  // model / effort / permission for this scope. buildArgs supplies the
  // permission flag too (default = --dangerously-skip-permissions), so the
  // previous always-bypass behavior is unchanged when nothing is configured.
  const args = [
    '--print',
    '--output-format',
    'stream-json',
    '--include-partial-messages',
    '--verbose',
    ...buildArgs('claude', settings),
  ];
  if (resuming) args.push('--resume', sessionId);
  else args.push('--session-id', sessionId);
  args.push(String(prompt));

  return spawnStream({
    cmd: 'claude',
    args,
    cwd,
    label: 'claude',
    signal,
    onLine: (line) => {
      let event;
      try {
        event = JSON.parse(line);
      } catch (_err) {
        return;
      }
      if (event.session_id) sessionId = event.session_id;
      if (
        event.type === 'assistant' &&
        event.message &&
        Array.isArray(event.message.content)
      ) {
        for (const block of event.message.content) {
          if (block.type === 'text' && block.text) {
            emitDelta(block.text);
            emit(onEvent, `Claude: ${oneLine(block.text)}`);
          } else if (block.type === 'tool_use') {
            emit(onEvent, `Tool: ${toolBrief(block.name, block.input)}`);
          }
        }
      } else if (event.type === 'result') {
        if (event.subtype && event.subtype !== 'success') isError = true;
        if (typeof event.result === 'string') finalText = event.result;
      }
    },
    finalize: ({ stderr }) => {
      const error = String(stderr).trim();
      if (finalText.trim()) {
        if (!isError) setSession(sessionKey, { id: sessionId });
        if (isError && isAuthError(finalText)) return { __authError: true };
        return `${isError ? 'Claude returned an error:\n' : ''}${finalText.trim()}`;
      }
      // Resume can fail if the CLI removed an old session. Drop it and retry.
      if (
        resuming &&
        /no conversation|session.*(not found|does not exist)|no such session|could not find/i.test(
          error,
        )
      ) {
        clearSession(sessionKey);
        return { __retry: true };
      }
      if (isAuthError(error)) return { __authError: true };
      return error || '(claude produced no output)';
    },
  }).then((result) => {
    if (result && result.__retry) {
      emit(onEvent, 'The old session is no longer valid. Retrying with a new session...');
      return runClaude(prompt, onEvent, sessionKey, signal, workdir, settings);
    }
    if (result && result.__authError) throw new AgentAuthError('claude');
    return result;
  });
}

function codexItemLabel(item) {
  const type = item.type || item.item_type;
  if (type === 'command_execution') {
    return `Command: ${oneLine(item.command || '', 80)}`;
  }
  if (type === 'file_change' || type === 'patch_apply') {
    return 'File change';
  }
  if (type === 'agent_message') {
    return `Codex: ${oneLine(item.text || '')}`;
  }
  if (type === 'reasoning') return null;
  if (type === 'mcp_tool_call') {
    return `MCP: ${oneLine(item.tool || item.name || '', 60)}`;
  }
  if (type === 'web_search') {
    return `Search: ${oneLine(item.query || '', 60)}`;
  }
  return null;
}

function runCodex(prompt, onEvent, sessionKey, signal, workdir, settings) {
  const cwd = workdir || getDefaultWorkdir();
  const prior = getSession(sessionKey);
  const resuming = !!(prior && prior.id);
  const lastMsg = path.join(
    os.tmpdir(),
    `codex-last-${process.pid}-${Date.now()}.txt`,
  );

  // buildArgs supplies model (-m), effort (-c model_reasoning_effort=) and
  // permission (default = --dangerously-bypass-approvals-and-sandbox). The `-c`
  // forms work for both `exec` and `exec resume`.
  const common = [
    '--json',
    ...buildArgs('codex', settings),
    '--skip-git-repo-check',
    '-o',
    lastMsg,
  ];
  // The resume subcommand does not support -C, so spawn cwd selects the repo;
  // new sessions still pass -C explicitly.
  const args = resuming
    ? ['exec', 'resume', ...common, prior.id, String(prompt)]
    : [
        'exec',
        ...common,
        '-C',
        cwd,
        String(prompt),
      ];

  let threadId = resuming ? prior.id : null;
  let sawTextDelta = false;
  const emitDelta = makeDeltaEmitter(onEvent);

  return spawnStream({
    cmd: 'codex',
    args,
    cwd,
    label: 'codex',
    signal,
    onLine: (line) => {
      let event;
      try {
        event = JSON.parse(line);
      } catch (_err) {
        return;
      }
      if (event.type === 'thread.started' && event.thread_id) {
        threadId = event.thread_id;
      }
      const deltaText =
        typeof event.text === 'string'
          ? event.text
          : typeof event.delta === 'string'
            ? event.delta
            : '';
      if (event.type && String(event.type).includes('delta') && deltaText) {
        sawTextDelta = true;
        emitDelta(deltaText);
      }
      if (event.type !== 'item.completed' || !event.item) return;
      if (event.item.type === 'agent_message' && event.item.text) {
        if (sawTextDelta) emitDelta(event.item.text);
      }
      const label = codexItemLabel(event.item);
      if (label) emit(onEvent, label);
    },
    finalize: ({ code, stdout, stderr }) => {
      let text = '';
      try {
        text = fs.readFileSync(lastMsg, 'utf-8').trim();
        fs.unlinkSync(lastMsg);
      } catch (_err) {
        // Fall back to process output.
      }
      const error = String(stderr).trim();
      if (
        !text &&
        resuming &&
        /no.*session|session.*not found|unknown session|no recorded|not found/i.test(
          error,
        )
      ) {
        clearSession(sessionKey);
        return { __retry: true };
      }
      if (text) {
        if (threadId) setSession(sessionKey, { id: threadId });
        return text;
      }
      if (isAuthError(error) || isAuthError(stdout)) return { __authError: true };
      return fallback(stdout, stderr, code, 'codex');
    },
  }).then((result) => {
    if (result && result.__retry) {
      emit(onEvent, 'The old session is no longer valid. Retrying with a new session...');
      return runCodex(prompt, onEvent, sessionKey, signal, workdir, settings);
    }
    if (result && result.__authError) throw new AgentAuthError('codex');
    return result;
  });
}

// agy cannot take an explicit new session ID. It records the latest
// conversation per cwd in last_conversations.json, which we read after a run
// and reuse with --conversation next time.
const AGY_LAST_CONV = path.join(
  os.homedir(),
  '.gemini',
  'antigravity-cli',
  'cache',
  'last_conversations.json',
);

function runAgy(prompt, onEvent, sessionKey, signal, workdir, settings) {
  const cwd = workdir || getDefaultWorkdir();
  const prior = getSession(sessionKey);
  emit(onEvent, 'Antigravity is working...');
  // agy exposes no model/effort; buildArgs only yields the permission flag
  // (default = --dangerously-skip-permissions).
  const args = [
    '--print',
    String(prompt),
    ...buildArgs('agy', settings),
    '--add-dir',
    cwd,
  ];
  if (prior && prior.id) args.push('--conversation', prior.id);
  return spawnStream({
    cmd: 'agy',
    args,
    cwd,
    label: 'antigravity',
    onLine: null,
    signal,
    finalize: ({ code, stdout, stderr }) => {
      const text = String(stdout).trim();
      // Capture this conversation ID by cwd for the next turn.
      let convId = null;
      try {
        const map = JSON.parse(fs.readFileSync(AGY_LAST_CONV, 'utf-8'));
        if (map[cwd]) {
          convId = map[cwd];
          setSession(sessionKey, { id: convId });
        }
      } catch (_err) {
        // If it is unavailable, the next turn starts a new conversation.
      }

      // agy --print can emit the entire resumed conversation to stdout. Read
      // the transcript and return only the last MODEL PLANNER_RESPONSE.
      if (convId) {
        try {
          const logDir = path.join(
            os.homedir(),
            '.gemini',
            'antigravity-cli',
            'brain',
            convId,
            '.system_generated',
            'logs',
          );
          const fullPath = path.join(logDir, 'transcript_full.jsonl');
          const normalPath = path.join(logDir, 'transcript.jsonl');
          const targetPath = fs.existsSync(fullPath) ? fullPath : normalPath;
          if (fs.existsSync(targetPath)) {
            const lines = fs
              .readFileSync(targetPath, 'utf-8')
              .trim()
              .split('\n');
            for (let i = lines.length - 1; i >= 0; i--) {
              if (!lines[i].trim()) continue;
              try {
                const obj = JSON.parse(lines[i]);
                if (
                  obj.source === 'MODEL' &&
                  obj.type === 'PLANNER_RESPONSE' &&
                  obj.content
                ) {
                  return obj.content.trim();
                }
              } catch (_err) {
                // Skip malformed transcript lines.
              }
            }
          }
        } catch (_err) {
          // Fall back to stdout if transcript parsing fails.
        }
      }

      if (!text && (isAuthError(stdout) || isAuthError(stderr))) {
        return { __authError: true };
      }
      return text || fallback(stdout, stderr, code, 'agy');
    },
  }).then((result) => {
    if (result && result.__authError) throw new AgentAuthError('agy');
    return result;
  });
}

const AGENTS = {
  claude: {
    key: 'claude',
    label: 'Claude Code',
    description: 'Anthropic Claude Code CLI',
    run: runClaude,
  },
  codex: {
    key: 'codex',
    label: 'Codex',
    description: 'OpenAI Codex CLI',
    run: runCodex,
  },
  agy: {
    key: 'agy',
    label: 'Antigravity',
    description: 'Antigravity CLI',
    run: runAgy,
  },
};

const DEFAULT_AGENT = 'claude';

function listAgents() {
  return Object.values(AGENTS).map(({ key, label, description }) => ({
    key,
    label,
    description,
  }));
}

function getAgent(key) {
  return AGENTS[key] || null;
}

async function runAgent(agentKey, prompt, onEvent, options = {}) {
  const agent = getAgent(agentKey);
  if (!agent) {
    throw new Error(`Unknown agent: ${agentKey}`);
  }
  const sessionKey = options.sessionKey || agent.key;
  return agent.run(
    prompt,
    onEvent,
    sessionKey,
    options.signal,
    options.workdir,
    options.settings,
  );
}

module.exports = {
  AGENTS,
  AgentCancelledError,
  AgentAuthError,
  DEFAULT_AGENT,
  TIMEOUT_MS,
  listAgents,
  getAgent,
  runAgent,
  getSession,
  clearSession,
};
