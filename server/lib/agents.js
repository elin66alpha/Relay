'use strict';

const { spawn } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { getDefaultWorkdir } = require('./workdir');
const { buildArgs } = require('./agent-options');
const { createJsonStore } = require('./json-store');

const TIMEOUT_MS = parseInt(
  process.env.AGENT_TIMEOUT_MS || String(60 * 60 * 1000),
  10,
);

// Cap how much process output we hold in memory. A long `claude --verbose
// stream-json` run can emit tens of MB to stdout; the captured buffer is only
// used as an error fallback (the real reply is parsed line-by-line or read from
// codex's -o file), so keeping just the tail bounds memory without losing the
// most recent, most relevant output.
const MAX_CAPTURED_OUTPUT = 8 * 1024 * 1024;

function appendCapped(buffer, text) {
  const next = buffer + text;
  return next.length > MAX_CAPTURED_OUTPUT
    ? next.slice(next.length - MAX_CAPTURED_OUTPUT)
    : next;
}

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

// Cached, atomic store for the resumable-session map. The cache keeps the
// per-turn getSession lookup off the disk, and the atomic write means a crash
// mid-save can't truncate the file.
const sessionStore = createJsonStore(SESSION_FILE, { defaultValue: {} });

function getSession(sessionKey) {
  return sessionStore.load()[sessionKey] || null;
}

function setSession(sessionKey, value) {
  sessionStore.mutate((sessions) => {
    sessions[sessionKey] = value;
  });
}

function clearSession(sessionKey) {
  if (!(sessionKey in sessionStore.load())) return false;
  sessionStore.mutate((sessions) => {
    delete sessions[sessionKey];
  });
  return true;
}

// Experimental agents (opencode, hermes) are only offered once their CLI is
// actually present on the host, so the app hides them until installed. Some
// installers (opencode) put the binary in a per-user dir that isn't on the
// server's PATH, so detection scans PATH first, then known fallback locations.
// Results are cached briefly so /api/agents stays fast.
const LOCATE_BIN_TTL_MS = 60 * 1000;
const locateBinCache = new Map();

const BIN_FALLBACKS = {
  opencode: [path.join(os.homedir(), '.opencode', 'bin', 'opencode')],
  hermes: [path.join(os.homedir(), '.local', 'bin', 'hermes')],
};

function executableInPath(bin) {
  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const exts =
    process.platform === 'win32'
      ? (process.env.PATHEXT || '.EXE;.CMD;.BAT').split(';')
      : [''];
  for (const dir of dirs) {
    for (const ext of exts) {
      const full = path.join(dir, bin + ext);
      try {
        fs.accessSync(full, fs.constants.X_OK);
        return full;
      } catch (_err) {
        // Keep scanning.
      }
    }
  }
  return null;
}

// Resolve a CLI to a runnable path: PATH first (return the bare name so spawn
// uses PATH), then per-user fallback locations (return the absolute path).
// Returns null when the binary can't be found anywhere.
function locateBin(bin) {
  const cached = locateBinCache.get(bin);
  if (cached && Date.now() - cached.at < LOCATE_BIN_TTL_MS) {
    return cached.value;
  }
  let value = executableInPath(bin) ? bin : null;
  if (!value) {
    for (const candidate of BIN_FALLBACKS[bin] || []) {
      try {
        fs.accessSync(candidate, fs.constants.X_OK);
        value = candidate;
        break;
      } catch (_err) {
        // Try the next candidate.
      }
    }
  }
  locateBinCache.set(bin, { value, at: Date.now() });
  return value;
}

function commandExists(bin) {
  return locateBin(bin) !== null;
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
      stdout = appendCapped(stdout, text);
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
      stderr = appendCapped(stderr, chunk.toString());
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

// Shared tail for every runner: resolve the __retry marker (a stale resumed
// session was cleared — run the turn once more from scratch) and the
// __authError marker (raise a typed error instead of returning CLI text).
function finishRun(resultPromise, { agentKey, onEvent, retry }) {
  return resultPromise.then((result) => {
    if (result && result.__retry && retry) {
      emit(onEvent, 'The old session is no longer valid. Retrying with a new session...');
      return retry();
    }
    if (result && result.__authError) throw new AgentAuthError(agentKey);
    return result;
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

// Core Claude invocation shared by the normal chat runner and the /btw sidekick.
// `resumeId` resumes that session (optionally forked so the original is left
// untouched); when null a brand-new session is started. The resolved/forked
// session id is persisted under `sessionKey`.
function runClaudeInvocation({
  prompt,
  onEvent,
  signal,
  workdir,
  settings,
  sessionKey,
  resumeId = null,
  forkSession = false,
  canRetry = true,
  retry,
}) {
  const cwd = workdir || getDefaultWorkdir();
  const resuming = !!resumeId;
  // Resume reuses the saved session ID; new conversations use our UUID as
  // --session-id until the CLI reports the canonical ID.
  let sessionId = resuming ? resumeId : crypto.randomUUID();
  let finalText = '';
  let isError = false;
  // A turn can contain several assistant messages (Claude's mid-task follow-up
  // notes, then a final summary). Each distinct message id marks a new segment;
  // emitting a `segment` boundary lets the app keep every message with its own
  // timestamp instead of collapsing them into the final result text.
  let emitDelta = makeDeltaEmitter(onEvent);
  let currentMsgId = null;

  // model / effort / permission for this scope. buildArgs supplies the
  // permission flag too; an unconfigured scope defaults to the acceptEdits
  // "auto" tier (--permission-mode acceptEdits), not full bypass.
  const args = [
    '--print',
    '--output-format',
    'stream-json',
    '--include-partial-messages',
    '--verbose',
    ...buildArgs('claude', settings),
  ];
  if (resuming) {
    args.push('--resume', sessionId);
    // Forking branches the conversation into a new session id, inheriting the
    // original's full memory without writing back to it — this is how /btw asks
    // a side question without disturbing the main task.
    if (forkSession) args.push('--fork-session');
  } else {
    args.push('--session-id', sessionId);
  }
  args.push(String(prompt));

  return finishRun(spawnStream({
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
        const msgId = event.message.id || 'msg';
        if (currentMsgId !== null && msgId !== currentMsgId) {
          // Claude moved on to a fresh follow-up message in the same turn.
          emit(onEvent, { type: 'segment' });
          emitDelta = makeDeltaEmitter(onEvent);
        }
        currentMsgId = msgId;
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
        if (!isError && sessionKey) setSession(sessionKey, { id: sessionId });
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
        if (canRetry) {
          if (sessionKey) clearSession(sessionKey);
          return { __retry: true };
        }
      }
      if (isAuthError(error)) return { __authError: true };
      return error || '(claude produced no output)';
    },
  }), { agentKey: 'claude', onEvent, retry });
}

function runClaude(prompt, onEvent, sessionKey, signal, workdir, settings) {
  const prior = getSession(sessionKey);
  return runClaudeInvocation({
    prompt,
    onEvent,
    signal,
    workdir,
    settings,
    sessionKey,
    resumeId: prior && prior.id ? prior.id : null,
    retry: () =>
      runClaude(prompt, onEvent, sessionKey, signal, workdir, settings),
  });
}

// The /btw sidekick: a read-only side question that inherits the main
// conversation's memory. The first question forks the main Claude session (so it
// sees everything so far without ever writing back to it); follow-up questions
// resume that fork so the side chat stays coherent. Permission is forced to the
// plan (read-only) tier — the sidekick never edits.
function runBtw(prompt, onEvent, options = {}) {
  const { mainSessionKey, btwSessionKey, signal, workdir, settings } = options;
  const readOnlySettings = { ...(settings || {}), permission: 'plan' };
  const btwPrior = getSession(btwSessionKey);
  if (btwPrior && btwPrior.id) {
    return runClaudeInvocation({
      prompt,
      onEvent,
      signal,
      workdir,
      settings: readOnlySettings,
      sessionKey: btwSessionKey,
      resumeId: btwPrior.id,
      // If the side fork is gone, clear it and re-fork from the main thread.
      canRetry: true,
      retry: () => runBtw(prompt, onEvent, options),
    });
  }
  const mainPrior = getSession(mainSessionKey);
  const mainSessionId = mainPrior && mainPrior.id ? mainPrior.id : null;
  return runClaudeInvocation({
    prompt,
    onEvent,
    signal,
    workdir,
    settings: readOnlySettings,
    sessionKey: btwSessionKey,
    resumeId: mainSessionId,
    forkSession: !!mainSessionId,
    // Forking from the main session: never clear the main session on failure.
    canRetry: false,
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
  // permission (default = the workspace-write tier, approvals disabled). The
  // `-c` forms work for both `exec` and `exec resume`.
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
  // Codex can emit several agent_message items in one turn; each completed
  // message starts a new segment so follow-ups keep their own timestamp.
  let emitDelta = makeDeltaEmitter(onEvent);
  let pendingNewSegment = false;

  return finishRun(spawnStream({
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
        if (pendingNewSegment) {
          emit(onEvent, { type: 'segment' });
          emitDelta = makeDeltaEmitter(onEvent);
          pendingNewSegment = false;
        }
        sawTextDelta = true;
        emitDelta(deltaText);
      }
      if (event.type !== 'item.completed' || !event.item) return;
      if (event.item.type === 'agent_message' && event.item.text) {
        if (sawTextDelta) emitDelta(event.item.text);
        // The next agent_message (if any) belongs to a new segment.
        pendingNewSegment = true;
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
  }), {
    agentKey: 'codex',
    onEvent,
    retry: () => runCodex(prompt, onEvent, sessionKey, signal, workdir, settings),
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

function agyReplyFromTranscript(lines, prompt) {
  const expectedPrompt = String(prompt || '').trim();
  if (!expectedPrompt) return '';

  const events = [];
  for (const line of lines) {
    if (!String(line || '').trim()) {
      events.push(null);
      continue;
    }
    try {
      events.push(JSON.parse(line));
    } catch (_err) {
      events.push(null);
    }
  }

  let currentUserInputIndex = -1;
  for (let i = 0; i < events.length; i++) {
    const obj = events[i];
    if (
      obj &&
      obj.source === 'USER_EXPLICIT' &&
      obj.type === 'USER_INPUT' &&
      typeof obj.content === 'string' &&
      obj.content.trim() === expectedPrompt
    ) {
      currentUserInputIndex = i;
    }
  }
  if (currentUserInputIndex === -1) return '';

  let reply = '';
  for (let i = currentUserInputIndex + 1; i < events.length; i++) {
    const obj = events[i];
    if (
      obj &&
      obj.source === 'MODEL' &&
      obj.type === 'PLANNER_RESPONSE' &&
      typeof obj.content === 'string' &&
      obj.content.trim()
    ) {
      reply = obj.content.trim();
    }
  }
  return reply;
}

function agyTranscriptPath(convId) {
  if (!convId) return null;
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
  if (fs.existsSync(fullPath)) return fullPath;
  if (fs.existsSync(normalPath)) return normalPath;
  return null;
}

function readTranscriptLines(targetPath) {
  return fs
    .readFileSync(targetPath, 'utf-8')
    .trim()
    .split('\n');
}

function agyTranscriptSnapshot(convId) {
  const targetPath = agyTranscriptPath(convId);
  if (!targetPath) return null;
  return {
    path: targetPath,
    lineCount: readTranscriptLines(targetPath).length,
  };
}

function runAgy(prompt, onEvent, sessionKey, signal, workdir, settings) {
  const cwd = workdir || getDefaultWorkdir();
  const prior = getSession(sessionKey);
  const priorConvId = prior && prior.id ? prior.id : null;
  const priorTranscript = agyTranscriptSnapshot(priorConvId);
  emit(onEvent, 'Antigravity is working...');
  // agy exposes no model/effort; buildArgs only yields the permission flag
  // (default = --sandbox). The prompt goes last, after every flag, so prompt
  // text starting with '-' can never be parsed as an option.
  const args = [
    '--print',
    ...buildArgs('agy', settings),
    '--add-dir',
    cwd,
  ];
  if (prior && prior.id) args.push('--conversation', prior.id);
  args.push(String(prompt));
  return finishRun(spawnStream({
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
      // the transcript, but only trust a response that appears after this
      // turn's USER_INPUT. Otherwise a stale transcript tail can make the app
      // show the previous answer for the current prompt.
      if (convId) {
        try {
          const targetPath = agyTranscriptPath(convId);
          if (targetPath) {
            const lines = readTranscriptLines(targetPath);
            const parseOnlyNewLines =
              priorConvId === convId &&
              priorTranscript &&
              priorTranscript.path === targetPath &&
              lines.length >= priorTranscript.lineCount;
            const transcriptReply = agyReplyFromTranscript(
              parseOnlyNewLines
                ? lines.slice(priorTranscript.lineCount)
                : lines,
              prompt,
            );
            if (transcriptReply) return transcriptReply;
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
  }), { agentKey: 'agy', onEvent });
}

// opencode: `run --format json` streams JSON events (one per line). Each carries
// the sessionID (captured for resume) and `type:"text"` parts hold the assistant
// output; a new messageID marks a follow-up message (segment). Model / effort
// (--variant) / permission flags come from buildArgs; -s resumes a session.
function runOpencode(prompt, onEvent, sessionKey, signal, workdir, settings) {
  const cwd = workdir || getDefaultWorkdir();
  const bin = locateBin('opencode') || 'opencode';
  const prior = getSession(sessionKey);
  const resuming = !!(prior && prior.id);
  let sessionId = resuming ? prior.id : null;
  // Accumulate the streamed text so a single-message turn has an authoritative
  // result; multi-message turns are rebuilt from segments by agent-turn.
  let finalText = '';
  const onDelta = (event) => {
    if (event && event.type === 'delta' && event.text) finalText += event.text;
    onEvent(event);
  };
  let emitDelta = makeDeltaEmitter(onDelta);
  let currentMsgId = null;

  const args = [
    'run',
    '--format',
    'json',
    ...buildArgs('opencode', settings),
    '--dir',
    cwd,
  ];
  if (resuming) args.push('--session', sessionId);
  args.push(String(prompt));

  return finishRun(spawnStream({
    cmd: bin,
    args,
    cwd,
    label: 'opencode',
    signal,
    onLine: (line) => {
      let event;
      try {
        event = JSON.parse(line);
      } catch (_err) {
        return;
      }
      if (event.sessionID) sessionId = event.sessionID;
      const part = event.part || {};
      if (event.type === 'text' && typeof part.text === 'string' && part.text) {
        const msgId = part.messageID || 'msg';
        if (currentMsgId !== null && msgId !== currentMsgId) {
          emit(onEvent, { type: 'segment' });
          emitDelta = makeDeltaEmitter(onDelta);
        }
        currentMsgId = msgId;
        emitDelta(part.text);
      } else if (event.type === 'tool' || part.type === 'tool') {
        const name = part.tool || part.name || event.tool || 'tool';
        emit(onEvent, `Tool: ${oneLine(name, 60)}`);
      }
    },
    finalize: ({ code, stdout, stderr }) => {
      if (finalText.trim()) {
        if (sessionId) setSession(sessionKey, { id: sessionId });
        return finalText.trim();
      }
      const error = String(stderr).trim();
      if (
        resuming &&
        /session.*(not found|does not exist)|no.*session|unknown session/i.test(
          error,
        )
      ) {
        clearSession(sessionKey);
        return { __retry: true };
      }
      if (isAuthError(error) || isAuthError(stdout)) return { __authError: true };
      return fallback(stdout, stderr, code, 'opencode');
    },
  }), {
    agentKey: 'opencode',
    onEvent,
    retry: () =>
      runOpencode(prompt, onEvent, sessionKey, signal, workdir, settings),
  });
}

// hermes: `chat -q <prompt> -Q` is the programmatic mode — it prints a
// `session_id: <id>` line (captured for resume) followed by the final response.
// --resume continues a stored session (verified to carry context). It is not a
// streaming protocol, so the reply lands as one segment.
function runHermes(prompt, onEvent, sessionKey, signal, workdir, settings) {
  const cwd = workdir || getDefaultWorkdir();
  const bin = locateBin('hermes') || 'hermes';
  const prior = getSession(sessionKey);
  const resuming = !!(prior && prior.id);
  emit(onEvent, 'Hermes is working...');

  const args = ['chat', '-q', String(prompt), '-Q', ...buildArgs('hermes', settings)];
  if (resuming) args.push('--resume', prior.id);

  return finishRun(spawnStream({
    cmd: bin,
    args,
    cwd,
    label: 'hermes',
    onLine: null,
    signal,
    finalize: ({ code, stdout, stderr }) => {
      const error = String(stderr).trim();
      // The reply is the clean stdout; hermes prints `session_id: <id>` and the
      // "↻ Resumed session ..." banner to stderr.
      const sidMatch = error.match(/session_id:\s*(\S+)/);
      const sid = sidMatch ? sidMatch[1] : null;
      const text = String(stdout)
        .split(/\r?\n/)
        .filter((line) => !/^\s*↻/.test(line))
        .join('\n')
        .trim();
      if (text) {
        if (sid) setSession(sessionKey, { id: sid });
        return text;
      }
      // A stored session can vanish (e.g. record_sessions disabled). Drop it and
      // retry once without --resume.
      if (
        resuming &&
        /session.*(not found|does not exist)|no.*session|unknown session/i.test(
          error,
        )
      ) {
        clearSession(sessionKey);
        return { __retry: true };
      }
      if (isAuthError(stdout) || isAuthError(error)) return { __authError: true };
      return fallback(stdout, stderr, code, 'hermes');
    },
  }), {
    agentKey: 'hermes',
    onEvent,
    retry: () =>
      runHermes(prompt, onEvent, sessionKey, signal, workdir, settings),
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
  // Experimental: hidden from the app until their CLI is detected on the host.
  opencode: {
    key: 'opencode',
    label: 'OpenCode',
    description: 'OpenCode CLI',
    run: runOpencode,
    bin: 'opencode',
    experimental: true,
  },
  hermes: {
    key: 'hermes',
    label: 'Hermes',
    description: 'Hermes CLI',
    run: runHermes,
    bin: 'hermes',
    experimental: true,
  },
};

const DEFAULT_AGENT = 'claude';

// Experimental agents only appear once their binary is on PATH; the stable
// agents are always listed.
function isAgentAvailable(agent) {
  if (!agent.experimental) return true;
  return commandExists(agent.bin || agent.key);
}

function listAgents() {
  return Object.values(AGENTS)
    .filter(isAgentAvailable)
    .map(({ key, label, description }) => ({
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
  runBtw,
  getSession,
  clearSession,
  agyReplyFromTranscript,
};
