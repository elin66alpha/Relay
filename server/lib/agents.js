'use strict';

const { spawn, spawnSync } = require('child_process');
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
const CODEX_STATE_DB = path.join(os.homedir(), '.codex', 'state_5.sqlite');
const AGY_ROOT = path.join(os.homedir(), '.gemini', 'antigravity-cli');
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

function sqlIdentifier(value) {
  return `"${String(value).replace(/"/g, '""')}"`;
}

function sqlLiteral(value) {
  if (value === null || value === undefined) return 'NULL';
  if (typeof value === 'number') {
    return Number.isFinite(value) ? String(value) : 'NULL';
  }
  if (typeof value === 'boolean') return value ? '1' : '0';
  return `'${String(value).replace(/'/g, "''")}'`;
}

function sqliteRun(dbPath, sql, options = {}) {
  const args = [];
  if (options.json) args.push('-json');
  args.push(dbPath, sql);
  const result = spawnSync('sqlite3', args, {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    const detail = String(result.stderr || result.stdout || '').trim();
    throw new Error(detail || `sqlite3 exited with code ${result.status}`);
  }
  return String(result.stdout || '');
}

function sqliteJson(dbPath, sql) {
  const raw = sqliteRun(dbPath, sql, { json: true }).trim();
  return raw ? JSON.parse(raw) : [];
}

function sqliteExec(dbPath, sql) {
  sqliteRun(dbPath, `PRAGMA busy_timeout=5000; ${sql}`);
}

function copySqliteDatabase(srcPath, destPath) {
  try {
    sqliteExec(srcPath, `VACUUM INTO ${sqlLiteral(destPath)};`);
  } catch (_err) {
    fs.copyFileSync(srcPath, destPath, fs.constants.COPYFILE_EXCL);
  }
}

function replaceExactTextInFile(filePath, from, to) {
  const text = fs.readFileSync(filePath, 'utf8');
  if (!text.includes(from)) return;
  fs.writeFileSync(filePath, text.split(from).join(to));
}

function replaceExactTextInTree(rootDir, from, to) {
  if (!fs.existsSync(rootDir)) return;
  const stack = [rootDir];
  while (stack.length) {
    const current = stack.pop();
    const entries = fs.readdirSync(current, { withFileTypes: true });
    for (const entry of entries) {
      const entryPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(entryPath);
        continue;
      }
      if (!entry.isFile()) continue;
      if (!/\.(json|jsonl|md|txt|log)$/i.test(entry.name)) continue;
      try {
        replaceExactTextInFile(entryPath, from, to);
      } catch (_err) {
        // Best-effort cleanup of visible text references inside the copied tree.
      }
    }
  }
}

// Some installers (opencode) put the binary in a per-user dir that isn't on the
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
    // Decode as UTF-8 at the stream layer so Node's StringDecoder buffers any
    // multi-byte character (e.g. a 3-byte Chinese glyph) that straddles a chunk
    // boundary. Calling chunk.toString() per-chunk would split it and emit U+FFFD
    // replacement characters (the "���" tofu) into the output.
    proc.stdout.setEncoding('utf8');
    proc.stderr.setEncoding('utf8');

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
  args.push('--', String(prompt));

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

function runBtwAgent(agentKey, prompt, onEvent, options = {}) {
  if (agentKey === 'claude') return runBtw(prompt, onEvent, options);
  if (agentKey === 'codex') return runCodexBtw(prompt, onEvent, options);
  if (agentKey === 'agy') return runAgyBtw(prompt, onEvent, options);
  throw new Error(`BTW is not available for ${agentKey || 'this agent'}`);
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

function codexRolloutCopy(parentRolloutPath, parentThreadId, childThreadId) {
  const source = fs.readFileSync(parentRolloutPath, 'utf8');
  const hasTrailingNewline = source.endsWith('\n');
  const rawLines = hasTrailingNewline
    ? source.slice(0, -1).split('\n')
    : source.split('\n');
  const lines = [];
  for (let i = 0; i < rawLines.length; i++) {
    const line = rawLines[i];
    if (!line.trim()) continue;
    try {
      JSON.parse(line);
      lines.push(line.split(parentThreadId).join(childThreadId));
    } catch (_err) {
      // If the source thread is actively being written, the last line may be a
      // partial JSON record. Drop that one so the child rollout stays readable.
      if (i !== rawLines.length - 1 || hasTrailingNewline) {
        lines.push(line.split(parentThreadId).join(childThreadId));
      }
    }
  }
  return `${lines.join('\n')}\n`;
}

function codexChildRolloutPath(parentRolloutPath, parentThreadId, childThreadId) {
  const dir = path.dirname(parentRolloutPath);
  const base = path.basename(parentRolloutPath);
  if (base.includes(parentThreadId)) {
    return path.join(dir, base.split(parentThreadId).join(childThreadId));
  }
  const stamp = new Date()
    .toISOString()
    .replace(/\.\d+Z$/, '')
    .replace(/:/g, '-');
  return path.join(dir, `rollout-${stamp}-${childThreadId}.jsonl`);
}

function cloneCodexThread(parentThreadId) {
  if (!UUID_RE.test(String(parentThreadId || ''))) {
    throw new Error('Cannot fork Codex BTW: main Codex session id is invalid.');
  }
  if (!fs.existsSync(CODEX_STATE_DB)) {
    throw new Error('Cannot fork Codex BTW: Codex state database was not found.');
  }

  const rows = sqliteJson(
    CODEX_STATE_DB,
    `SELECT * FROM threads WHERE id = ${sqlLiteral(parentThreadId)} LIMIT 1;`,
  );
  const parent = rows[0];
  if (!parent) {
    throw new Error('Cannot fork Codex BTW: main Codex thread was not found.');
  }
  if (!parent.rollout_path || !fs.existsSync(parent.rollout_path)) {
    throw new Error(
      'Cannot fork Codex BTW: main Codex rollout file was not found.',
    );
  }

  const childThreadId = crypto.randomUUID();
  const childRolloutPath = codexChildRolloutPath(
    parent.rollout_path,
    parentThreadId,
    childThreadId,
  );
  fs.mkdirSync(path.dirname(childRolloutPath), { recursive: true });
  fs.writeFileSync(
    childRolloutPath,
    codexRolloutCopy(parent.rollout_path, parentThreadId, childThreadId),
    { flag: 'wx' },
  );

  const nowMs = Date.now();
  const now = Math.floor(nowMs / 1000);
  const child = {
    ...parent,
    id: childThreadId,
    rollout_path: childRolloutPath,
    created_at: now,
    updated_at: now,
    created_at_ms: nowMs,
    updated_at_ms: nowMs,
    tokens_used: 0,
    archived: 0,
    archived_at: null,
    title: parent.title ? `BTW: ${parent.title}` : 'BTW side conversation',
    preview: parent.preview ? `BTW: ${parent.preview}` : '',
  };
  const columns = Object.keys(child);
  const insertThread = [
    `INSERT INTO threads (${columns.map(sqlIdentifier).join(', ')})`,
    `VALUES (${columns
      .map((column) => sqlLiteral(child[column]))
      .join(', ')});`,
  ].join(' ');
  const insertTools = [
    'INSERT OR IGNORE INTO thread_dynamic_tools',
    '(thread_id, position, name, description, input_schema, defer_loading,',
    'namespace)',
    `SELECT ${sqlLiteral(childThreadId)}, position, name, description,`,
    'input_schema, defer_loading, namespace',
    `FROM thread_dynamic_tools WHERE thread_id = ${sqlLiteral(parentThreadId)};`,
  ].join(' ');
  const insertEdge = [
    'INSERT OR REPLACE INTO thread_spawn_edges',
    '(parent_thread_id, child_thread_id, status)',
    `VALUES (${sqlLiteral(parentThreadId)},`,
    `${sqlLiteral(childThreadId)}, 'active');`,
  ].join(' ');
  try {
    sqliteExec(
      CODEX_STATE_DB,
      `BEGIN IMMEDIATE; ${insertThread} ${insertTools} ${insertEdge} COMMIT;`,
    );
  } catch (err) {
    // The transaction is atomic, but the rollout file was written first. If the
    // insert fails there is no thread row referencing it, so drop the orphan.
    try {
      fs.unlinkSync(childRolloutPath);
    } catch (_err) {
      // Already gone.
    }
    throw err;
  }
  return childThreadId;
}

function runCodex(
  prompt,
  onEvent,
  sessionKey,
  signal,
  workdir,
  settings,
  retryOverride,
) {
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
    ? ['exec', 'resume', ...common, prior.id, '--', String(prompt)]
    : [
        'exec',
        ...common,
        '-C',
        cwd,
        '--',
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
    retry:
      retryOverride ||
      (() => runCodex(prompt, onEvent, sessionKey, signal, workdir, settings)),
  });
}

function runCodexBtw(prompt, onEvent, options = {}) {
  const { mainSessionKey, btwSessionKey, signal, workdir, settings } = options;
  const readOnlySettings = { ...(settings || {}), permission: 'read-only' };
  const btwPrior = getSession(btwSessionKey);
  if (!btwPrior || !btwPrior.id) {
    const mainPrior = getSession(mainSessionKey);
    const mainThreadId = mainPrior && mainPrior.id ? mainPrior.id : null;
    if (mainThreadId) {
      const childThreadId = cloneCodexThread(mainThreadId);
      setSession(btwSessionKey, {
        id: childThreadId,
        parentId: mainThreadId,
        forkedAt: new Date().toISOString(),
      });
    }
  }
  return runCodex(
    prompt,
    onEvent,
    btwSessionKey,
    signal,
    workdir,
    readOnlySettings,
    () => runCodexBtw(prompt, onEvent, options),
  );
}

// agy cannot take an explicit new session ID. It records the latest
// conversation per cwd in last_conversations.json, which we read after a run
// and reuse with --conversation next time.
const AGY_LAST_CONV = path.join(
  AGY_ROOT,
  'cache',
  'last_conversations.json',
);
const AGY_CONVERSATIONS_DIR = path.join(AGY_ROOT, 'conversations');
const AGY_BRAIN_DIR = path.join(AGY_ROOT, 'brain');

function cloneAgyConversation(parentConversationId) {
  if (!UUID_RE.test(String(parentConversationId || ''))) {
    throw new Error(
      'Cannot fork Antigravity BTW: main conversation id is invalid.',
    );
  }
  const childConversationId = crypto.randomUUID();
  const srcDb = path.join(AGY_CONVERSATIONS_DIR, `${parentConversationId}.db`);
  const destDb = path.join(AGY_CONVERSATIONS_DIR, `${childConversationId}.db`);
  if (!fs.existsSync(srcDb)) {
    throw new Error(
      'Cannot fork Antigravity BTW: main conversation database was not found.',
    );
  }

  fs.mkdirSync(AGY_CONVERSATIONS_DIR, { recursive: true });
  copySqliteDatabase(srcDb, destDb);
  try {
    sqliteExec(
      destDb,
      `UPDATE trajectory_meta SET cascade_id = ${sqlLiteral(childConversationId)}
       WHERE cascade_id = ${sqlLiteral(parentConversationId)};`,
    );
  } catch (_err) {
    // The filename is the primary lookup key. If metadata rewriting fails, keep
    // the cloned database; agy can still resume it by --conversation.
  }

  const srcPb = path.join(AGY_CONVERSATIONS_DIR, `${parentConversationId}.pb`);
  const destPb = path.join(AGY_CONVERSATIONS_DIR, `${childConversationId}.pb`);
  if (fs.existsSync(srcPb) && !fs.existsSync(destPb)) {
    fs.copyFileSync(srcPb, destPb, fs.constants.COPYFILE_EXCL);
  }

  const srcBrain = path.join(AGY_BRAIN_DIR, parentConversationId);
  const destBrain = path.join(AGY_BRAIN_DIR, childConversationId);
  if (fs.existsSync(srcBrain) && !fs.existsSync(destBrain)) {
    fs.cpSync(srcBrain, destBrain, { recursive: true, errorOnExist: true });
    replaceExactTextInTree(destBrain, parentConversationId, childConversationId);
  }
  return childConversationId;
}

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

// Assemble agy's argv. Pure and exported so the prompt-placement contract is
// pinned by a regression test without spawning the binary.
//
// The one thing that matters here: agy's --print/--prompt is a VALUE flag — it
// takes the prompt as its argument, not a trailing positional. A bare `--print`
// followed by other flags swallows the next one (e.g. --sandbox) as the prompt
// and drops the user's message. So the prompt must ride as a single
// `--print=<prompt>` token; the `=` form also keeps a prompt that starts with
// '-' or spans multiple lines safely inside the value. buildArgs supplies the
// selected model (--model) plus the permission flag (default --sandbox).
function buildAgyArgs({ settings, cwd, conversationId, prompt }) {
  const args = [...buildArgs('agy', settings), '--add-dir', cwd];
  if (conversationId) args.push('--conversation', conversationId);
  args.push(`--print=${String(prompt)}`);
  return args;
}

function runAgy(prompt, onEvent, sessionKey, signal, workdir, settings) {
  const cwd = workdir || getDefaultWorkdir();
  const prior = getSession(sessionKey);
  const priorConvId = prior && prior.id ? prior.id : null;
  const priorTranscript = agyTranscriptSnapshot(priorConvId);
  emit(onEvent, 'Antigravity is working...');
  const args = buildAgyArgs({
    settings,
    cwd,
    conversationId: priorConvId,
    prompt,
  });
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

function runAgyBtw(prompt, onEvent, options = {}) {
  const { mainSessionKey, btwSessionKey, signal, workdir, settings } = options;
  const sandboxSettings = { ...(settings || {}), permission: 'sandbox' };
  const btwPrior = getSession(btwSessionKey);
  if (!btwPrior || !btwPrior.id) {
    const mainPrior = getSession(mainSessionKey);
    const mainConversationId = mainPrior && mainPrior.id ? mainPrior.id : null;
    if (mainConversationId) {
      const childConversationId = cloneAgyConversation(mainConversationId);
      setSession(btwSessionKey, {
        id: childConversationId,
        parentId: mainConversationId,
        forkedAt: new Date().toISOString(),
      });
    }
  }
  return runAgy(prompt, onEvent, btwSessionKey, signal, workdir, sandboxSettings);
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
  args.push('--', String(prompt));

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
  // Experimental: listed in the app with explicit install/auth status.
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
  commandExists,
  runAgent,
  runBtw,
  runBtwAgent,
  getSession,
  clearSession,
  agyReplyFromTranscript,
  buildAgyArgs,
};
