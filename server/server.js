'use strict';

require('dotenv').config();

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, execFile } = require('child_process');
const { randomUUID } = require('crypto');
const express = require('express');
const compression = require('compression');

const {
  DEFAULT_AGENT,
  TIMEOUT_MS,
  getAgent,
  listAgents,
  runAgent,
  clearSession,
} = require('./lib/agents');
const {
  WorkdirError,
  resolveWorkdir,
  getDefaultWorkdir,
  resolveRequestWorkdir,
  validateWorkdir,
} = require('./lib/workdir');
const {
  FilesystemError,
  listAbsoluteDirectory,
  prepareDownload,
  prepareDownloadAbsolute,
  resolveUploadTarget,
  resolveAbsoluteUploadTarget,
  uploadedEntry,
} = require('./lib/filesystem');
const {
  hasConfiguredToken,
  isTokenAllowed,
  listTokenSummaries,
  revokeTokenById,
} = require('./lib/tokens');
const { buildUsageReport } = require('./lib/usage');
const { describeAgent, CLI } = require('./lib/agent-options');
const { getSettings, setSettings } = require('./lib/agent-settings');
const push = require('./lib/push');
const fcm = require('./lib/fcm');
const { startQuotaWatch } = require('./lib/quota-watch');
const { authStatus } = require('./lib/auth-status');
const { buildDiagnostics } = require('./lib/diagnostics');
const {
  readHistory,
  upsertHistoryMessage,
  updateHistoryMessage,
  finalizeStaleStreamingHistory,
  finalizeAllStaleStreamingHistory,
  clearHistory,
  redactSensitiveText,
  searchHistory,
  markdownForConversation,
} = require('./lib/history');
const {
  LEGACY_SESSION_ID,
  MAX_SESSIONS,
  listChatSessions,
  resolveChatSession,
  createChatSession,
  setActiveChatSession,
  touchChatSession,
  deleteChatSession,
  sessionScopeKey,
} = require('./lib/chat-sessions');
const {
  agentPayload,
  createChatResponder,
  createNoopResponder,
  runAgentTurn,
  sessionPayload,
} = require('./lib/agent-turn');
const {
  cancelQuotaSchedule,
  createQuotaSchedule,
  dueQuotaSchedulesForReset,
  listQuotaSchedules,
  markQuotaScheduleFailed,
  markQuotaScheduleRunning,
  markQuotaScheduleSent,
  reconcileRunningSchedules,
} = require('./lib/quota-schedules');
const cards = require('./lib/cards');
const { generateCardsForWorkdir } = require('./lib/chat-learner');

const PORT = parseInt(process.env.PORT || '8787', 10);
const HOST = process.env.HOST || '127.0.0.1';
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || '').replace(/\/+$/, '');
const ENABLE_QUOTA_WATCH = process.env.ENABLE_QUOTA_WATCH !== 'false';
const WEB_BUILD_DIR = path.join(__dirname, '..', 'build', 'web');
// Hard cap on a single download (file, or the uncompressed total behind a zip).
// Public tunnels can relay slowly or enforce throughput limits, so we refuse
// oversized downloads up front instead of letting the user wait on a transfer
// that will stall. Override with DOWNLOAD_MAX_BYTES if your network allows more.
const MAX_DOWNLOAD_BYTES = parseInt(
  process.env.DOWNLOAD_MAX_BYTES || String(300 * 1024 * 1024),
  10,
);
// Cap a single uploaded file. Some tunnels limit request bodies, so we refuse
// oversized uploads (the app also pre-checks before sending).
const MAX_UPLOAD_BYTES = parseInt(
  process.env.UPLOAD_MAX_BYTES || String(100 * 1024 * 1024),
  10,
);

const app = express();
const eventClients = new Set();
const activeRequests = new Map();
// Scopes currently executing an agent turn, keyed by `workdir\0agentKey[\0sessionId]`.
const runningScopes = new Set();
// Per-scope serial execution chains. A new message on a busy scope waits for the
// in-flight turn (the underlying `claude --resume` session cannot run two turns
// at once), then runs automatically. Maps scopeKey -> tail Promise.
const scopeChains = new Map();
const rawUpload = express.raw({
  type: 'application/octet-stream',
  // A hair above MAX_UPLOAD_BYTES so the handler returns our own clean JSON for
  // at-cap files; anything well over the cap is rejected by the parser below.
  limit: process.env.FILE_UPLOAD_LIMIT || '101mb',
});

// Turns the body-parser's "payload too large" (and any upstream error) into the
// same JSON shape the app understands, instead of Express's default HTML 413.
function uploadErrorHandler(err, req, res, next) {
  if (err && (err.type === 'entity.too.large' || err.status === 413)) {
    return res.status(413).json({
      error: 'upload exceeds the size limit',
      code: 'FS_UPLOAD_TOO_LARGE',
    });
  }
  return next(err);
}

// Compress responses before they cross the tunnel. The web bundle is the bulk of
// first-load bytes (main.dart.js ~3.6MB + canvaskit.wasm ~7MB); gzip cuts it ~60%,
// turning a multi-minute first load into seconds. `compressible` does not flag
// application/wasm, so allow it explicitly. Streaming/SSE responses set
// `Cache-Control: no-transform`, which compression honors by skipping them.
app.use(
  compression({
    filter(req, res) {
      const type = String(res.getHeader('Content-Type') || '');
      if (/application\/wasm/i.test(type)) return true;
      return compression.filter(req, res);
    },
  }),
);

app.use(express.json({ limit: '16mb' }));
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader(
    'Access-Control-Allow-Headers',
    'Content-Type, Authorization, X-Device-Id, X-Workdir',
  );
  res.setHeader('Access-Control-Expose-Headers', 'Content-Disposition');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  return next();
});

function requireAuth(req, res, next) {
  if (!hasConfiguredToken()) {
    return res.status(503).json({
      error: 'no app token is configured',
      code: 'TOKEN_NOT_CONFIGURED',
    });
  }
  const header = String(req.get('authorization') || '');
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  if (!isTokenAllowed(token)) {
    return res.status(401).json({ error: 'unauthorized' });
  }
  return next();
}

app.use('/api', requireAuth);

function bearerToken(req) {
  const header = String(req.get('authorization') || '');
  return header.startsWith('Bearer ') ? header.slice(7).trim() : '';
}

function formatUptime(seconds) {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  return `${d}d ${h}h ${m}m ${s}s`;
}

function sendWorkdirError(res, err) {
  if (err instanceof WorkdirError) {
    return res.status(err.status || 400).json({
      error: err.message,
      code: err.code,
      dir: err.dir,
    });
  }
  return res.status(500).json({ error: err.message });
}

function sendFilesystemError(res, err) {
  if (err instanceof FilesystemError) {
    return res.status(err.status || 400).json({
      error: err.message,
      code: err.code,
    });
  }
  return res.status(500).json({ error: err.message });
}

function queryBool(value) {
  return value === true || String(value || '').toLowerCase() === 'true';
}

function attachmentHeader(filename) {
  const fallback = String(filename || 'download')
    .replace(/[^\x20-\x7e]/g, '_')
    .replace(/["\\]/g, '_');
  return `attachment; filename="${fallback}"; filename*=UTF-8''${encodeURIComponent(filename)}`;
}

function safeDownloadName(value, fallback = 'download') {
  const cleaned = String(value || '')
    .replace(/[^\w.-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80);
  return cleaned || fallback;
}

function cleanupTempZip(zipPath) {
  fs.unlink(zipPath, () => {
    fs.rm(path.dirname(zipPath), { recursive: true, force: true }, () => {});
  });
}

function sendWindowsDirectoryZip(download, res) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-zip-'));
  const tempZip = path.join(tempDir, `${randomUUID()}.zip`);
  const sourcePath = path.join(download.zipCwd, download.zipEntryName);
  const powershell = process.env.POWERSHELL_BIN || 'powershell.exe';
  const child = spawn(
    powershell,
    [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      'Compress-Archive -LiteralPath $args[0] -DestinationPath $args[1] -Force',
      sourcePath,
      tempZip,
    ],
    { windowsHide: true },
  );
  let stderr = '';
  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });
  child.on('error', (err) => {
    cleanupTempZip(tempZip);
    if (!res.headersSent) {
      return res.status(500).json({ error: `zip failed: ${err.message}` });
    }
    return res.destroy(err);
  });
  child.on('close', (code) => {
    if (code !== 0) {
      cleanupTempZip(tempZip);
      const message = stderr.trim() || `zip exited with code ${code}`;
      if (!res.headersSent) {
        return res.status(500).json({ error: message });
      }
      return res.destroy(new Error(message));
    }
    return res.download(tempZip, download.filename, (err) => {
      cleanupTempZip(tempZip);
      if (err && !res.headersSent) {
        return sendFilesystemError(res, err);
      }
      return undefined;
    });
  });
}

function sendUnixDirectoryZip(download, res) {
  const child = spawn('zip', ['-r', '-q', '-y', '-', download.zipEntryName], {
    cwd: download.zipCwd,
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });
  child.on('error', (err) => {
    if (!res.headersSent) {
      return res.status(500).json({ error: `zip failed: ${err.message}` });
    }
    return res.destroy(err);
  });
  child.on('close', (code) => {
    if (code !== 0 && !res.destroyed) {
      const message = stderr.trim() || `zip exited with code ${code}`;
      if (!res.headersSent) {
        return res.status(500).json({ error: message });
      }
      return res.destroy(new Error(message));
    }
    return undefined;
  });
  res.setHeader('Content-Type', 'application/zip');
  res.setHeader('Content-Disposition', attachmentHeader(download.filename));
  // Defence in depth: the pre-flight size check uses the uncompressed total, so a
  // compliant zip is always smaller. If the stream ever exceeds the cap anyway
  // (e.g. files grew mid-zip), abort rather than blow the tunnel's budget.
  let sentBytes = 0;
  child.stdout.on('data', (chunk) => {
    sentBytes += chunk.length;
    if (sentBytes > MAX_DOWNLOAD_BYTES) {
      child.kill('SIGKILL');
      res.destroy();
    }
  });
  return child.stdout.pipe(res);
}

function sendDirectoryZip(download, res) {
  if (process.platform === 'win32') {
    return sendWindowsDirectoryZip(download, res);
  }
  return sendUnixDirectoryZip(download, res);
}

function sendEvent(type, payload) {
  const packet = `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;
  const scopeWorkdir = payload && payload.scopeWorkdir;
  for (const client of eventClients) {
    // Scope events carry a scopeWorkdir and only reach devices currently in that
    // work directory, so a conversation is shared across same-path devices.
    // Events without a scopeWorkdir (such as quota_reset) reach everyone.
    if (scopeWorkdir && client.workdir !== scopeWorkdir) {
      continue;
    }
    client.res.write(packet);
  }
}

function hasPresence(scopeWorkdir) {
  if (!scopeWorkdir) return false;
  for (const client of eventClients) {
    if (client.workdir === scopeWorkdir) return true;
  }
  return false;
}

function pushCategoriesFromBody(body) {
  const source =
    body &&
    body.categories &&
    typeof body.categories === 'object' &&
    !Array.isArray(body.categories)
      ? body.categories
      : body || {};
  return {
    quota: source.quota !== false,
    task: source.task !== false,
  };
}

function normalizeDeviceId(value) {
  const text = String(value || '').trim();
  if (!text) return '';
  if (!/^[A-Za-z0-9._-]{8,128}$/.test(text)) return '';
  return text;
}

// Session context = work directory + agent. Individual chat sessions hang under
// that context and each keeps its own history plus resumable CLI session. NUL
// separates parts so no real path can collide with the agent/session suffix.
const SCOPE_SEPARATOR = '\u0000';

function sessionContextKeyFor(agentKey, workdir) {
  return `${workdir}${SCOPE_SEPARATOR}${agentKey}`;
}

function scopeKeyFor(agentKey, workdir, sessionId) {
  return sessionScopeKey(sessionContextKeyFor(agentKey, workdir), sessionId);
}

// The work directory for a request: the device's x-workdir header, or the
// default for a device that has not chosen one yet. The path is created if
// missing. Throws WorkdirError for an invalid header, handled by the caller.
function requestWorkdir(req) {
  return resolveRequestWorkdir(req.get('x-workdir'));
}

const agentRequiredError = () => ({ status: 400, body: { error: 'agent is required' } });

function agentRequiredOrUnknownError(agentKey) {
  return {
    status: 400,
    body: { error: agentKey ? `unknown agent: ${agentKey}` : 'agent is required' },
  };
}

function resolveAgentScope(req, res, options = {}) {
  const {
    agentFrom = 'params',
    agentKey,
    sessionId,
    workdir: resolvedWorkdir,
    requireSession = true,
    agentError = () => ({ status: 404, body: { error: 'unknown agent', code: 'UNKNOWN_AGENT' } }),
    beforeWorkdir,
  } = options;
  const agentValues =
    agentFrom === 'body' ? req.body : agentFrom === 'query' ? req.query : req.params;
  const key = String(agentKey === undefined ? agentValues && agentValues.agent : agentKey).trim();
  const agent = getAgent(key);
  if (!agent) {
    const { status, body } = agentError(key);
    res.status(status).json(body);
    return null;
  }
  if (typeof beforeWorkdir === 'function' && beforeWorkdir({ agent, agentKey: key }) === false) return null;
  let workdir = resolvedWorkdir;
  if (!workdir) {
    try {
      workdir = requestWorkdir(req);
    } catch (err) {
      sendWorkdirError(res, err);
      return null;
    }
  }
  const contextKey = sessionContextKeyFor(agent.key, workdir);
  if (!requireSession) {
    return { agent, workdir, contextKey, session: null, scopeKey: contextKey };
  }
  const requestedSessionId = String(
    sessionId === undefined ? req.query && req.query.sessionId : sessionId,
  ).trim();
  const session = resolveChatSession(contextKey, requestedSessionId);
  if (!session) {
    res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
    return null;
  }
  return {
    agent,
    workdir,
    contextKey,
    session,
    scopeKey: scopeKeyFor(agent.key, workdir, session.id),
  };
}

// Resolve a workdir for read-only contexts (SSE subscription, status) without
// creating it; fall back to the default if the header is missing or invalid.
function eventWorkdir(req) {
  const raw = String(req.get('x-workdir') || '').trim();
  if (!raw) return getDefaultWorkdir();
  try {
    return resolveWorkdir(raw);
  } catch (_err) {
    return getDefaultWorkdir();
  }
}

// True when an agent turn is currently executing anywhere under this workdir.
function workdirBusy(workdir) {
  const prefix = `${workdir}${SCOPE_SEPARATOR}`;
  for (const key of runningScopes) {
    if (key.startsWith(prefix)) return true;
  }
  return false;
}

// Run taskFn after any in-flight turn on the same scope completes, so turns on a
// shared conversation execute one at a time. The returned promise settles with
// taskFn's result/error; the chain itself never rejects so later turns proceed.
function enqueueScope(scopeKey, taskFn) {
  const prev = scopeChains.get(scopeKey) || Promise.resolve();
  const run = prev.then(() => taskFn());
  const tail = run.catch(() => {});
  scopeChains.set(scopeKey, tail);
  tail.then(() => {
    if (scopeChains.get(scopeKey) === tail) scopeChains.delete(scopeKey);
  });
  return run;
}

// Broadcast a chat event to every device currently in the same work directory
// (including the originator, which ignores its own requestId). This is what
// makes a message sent on one device appear on the others in real time.
function broadcastScope(
  type,
  { scopeWorkdir, agent, session, requestId, deviceId, ...rest },
) {
  sendEvent(type, {
    scopeWorkdir,
    deviceId,
    requestId,
    agent: agentPayload(agent),
    ...(session ? { session: sessionPayload(session) } : {}),
    createdAt: new Date().toISOString(),
    ...rest,
  });
}

function taskCompletionSnippet(value) {
  const redacted = redactSensitiveText(value);
  const firstLine =
    redacted
      .split(/\r?\n/)
      .map((line) => line.replace(/\s+/g, ' ').trim())
      .find((line) => line.length > 0) || '';
  if (!firstLine) return 'Task completed.';
  if (firstLine.length <= 140) return firstLine;
  return `${firstLine.slice(0, 137)}...`;
}

function notifyTaskCompletion({ agent, scopeWorkdir, content }) {
  if (hasPresence(scopeWorkdir)) return;
  const title = `${agent.label} finished`;
  const titleZh = `${agent.label} 已完成`;
  const body = taskCompletionSnippet(content);
  push
    .notify({
      title,
      titleZh,
      message: body,
      messageZh: body,
      scopeWorkdir,
      category: 'task',
    })
    .catch((err) => console.warn(`[push] task_done: ${err.message}`));
  fcm
    .notify({
      title,
      titleZh,
      message: body,
      messageZh: body,
      scopeWorkdir,
      category: 'task',
    })
    .catch((err) => console.warn(`[fcm] task_done: ${err.message}`));
}

function agentTurnDependencies() {
  return {
    broadcastScope,
    enqueueScope,
    getSettings,
    runAgent,
    runningScopes,
    scopeChains,
    touchChatSession,
    updateHistoryMessage,
    upsertHistoryMessage,
  };
}

async function runScheduledQuotaMessage(schedule) {
  const agent = getAgent(schedule.agentKey);
  if (!agent) {
    markQuotaScheduleFailed(schedule.id, `unknown agent: ${schedule.agentKey}`);
    return;
  }

  const contextKey = sessionContextKeyFor(agent.key, schedule.workdir);
  const chatSession = resolveChatSession(contextKey, schedule.sessionId);
  if (!chatSession) {
    markQuotaScheduleFailed(schedule.id, 'scheduled chat session was deleted');
    return;
  }

  const runningSchedule = markQuotaScheduleRunning(schedule.id) || schedule;
  const requestId = `quota.${schedule.id}`;
  const deviceId = 'quota-scheduler';
  const scopeKey = scopeKeyFor(agent.key, schedule.workdir, chatSession.id);

  await runAgentTurn({
    agent,
    agentKey: agent.key,
    contextKey,
    defaultErrorCode: 'SCHEDULED_AGENT_ERROR',
    dependencies: agentTurnDependencies(),
    deviceId,
    finalizeBeforeDone: true,
    finalizeContent({ content, streamedText }) {
      return String(content || streamedText || '').trim();
    },
    historyMetadata: {
      scheduledQuotaMessageId: schedule.id,
      quotaSourceKey: schedule.sourceKey,
    },
    initialProgressLines: ['Scheduled after quota reset.'],
    onBeforeDone() {
      markQuotaScheduleSent(schedule.id);
    },
    onAfterDone() {
      sendEvent('quota_schedule_sent', {
        scopeWorkdir: schedule.workdir,
        schedule: {
          ...runningSchedule,
          status: 'sent',
          sentAt: new Date().toISOString(),
        },
        message: `Scheduled ${agent.label} message was sent after quota reset.`,
        messageZh: `已在额度刷新后发送预设的 ${agent.label} 消息。`,
        createdAt: new Date().toISOString(),
      });
    },
    onBeforeError({ errorMessage }) {
      markQuotaScheduleFailed(schedule.id, errorMessage);
    },
    onAfterError({ errorMessage }) {
      sendEvent('quota_schedule_failed', {
        scopeWorkdir: schedule.workdir,
        schedule: {
          ...runningSchedule,
          status: 'failed',
          error: errorMessage,
        },
        message: `Scheduled ${agent.label} message failed: ${errorMessage}`,
        messageZh: `预设的 ${agent.label} 消息发送失败：${errorMessage}`,
        createdAt: new Date().toISOString(),
      });
    },
    prompt: schedule.prompt,
    requestId,
    responder: createNoopResponder(),
    scopeKey,
    session: chatSession,
    workdir: schedule.workdir,
  });
}

async function processDueQuotaSchedules(info) {
  const sourceKey = info && info.key;
  const due = dueQuotaSchedulesForReset(sourceKey);
  for (const schedule of due) {
    try {
      await runScheduledQuotaMessage(schedule);
    } catch (err) {
      console.error(
        `[quota:${sourceKey}] scheduled message ${schedule.id} failed: ${err.message}`,
      );
      markQuotaScheduleFailed(schedule.id, err.message);
    }
  }
}

app.get('/api/health', (_req, res) => {
  res.json({ ok: true, time: new Date().toISOString() });
});

app.get('/api/agents', (_req, res) => {
  res.json({ defaultAgent: DEFAULT_AGENT, agents: listAgents() });
});

// Run a CLI binary with fixed argv (no user-controlled tokens) and resolve with
// its trimmed output. Used for `<cli> --version` and `<cli> update`.
function runCliCommand(bin, args, timeoutMs) {
  return new Promise((resolve) => {
    execFile(
      bin,
      args,
      { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 },
      (err, stdout, stderr) => {
        const out = String(stdout || '').trim();
        const errOut = String(stderr || '').trim();
        resolve({
          ok: !err,
          code: err && typeof err.code === 'number' ? err.code : err ? 1 : 0,
          stdout: out,
          stderr: errOut,
          text: out || errOut,
          timedOut: !!(err && err.killed),
        });
      },
    );
  });
}

async function cliVersion(agentKey) {
  const cli = CLI[agentKey];
  if (!cli) return '';
  const result = await runCliCommand(cli.bin, cli.versionArgs, 15000);
  // Versions print as e.g. "2.1.161 (Claude Code)" / "codex-cli 0.132.0".
  return result.ok ? result.text.split('\n')[0].trim() : '';
}

// Catalog of selectable model/effort/permission options for one agent
// (capability-aware; agy has no model/effort). Static, so no workdir needed.
app.get('/api/agent-options', (req, res) => {
  const agent = getAgent(String(req.query.agent || '').trim());
  if (!agent) {
    return res.status(400).json({ error: 'agent is required' });
  }
  return res.json({ ok: true, ...describeAgent(agent.key) });
});

// Current model/effort/permission selection for the request's workdir+agent
// scope (shared by every device in that scope).
app.get('/api/agent-settings', (req, res) => {
  const scope = resolveAgentScope(req, res, {
    agentFrom: 'query',
    requireSession: false,
    agentError: agentRequiredError,
  });
  if (!scope) return;
  const { agent, workdir, contextKey } = scope;
  return res.json({
    ok: true,
    agent: agent.key,
    workdir,
    settings: getSettings(agent.key, contextKey),
  });
});

// Update the selection for a scope. Body: { agent, model?, effort?, permission? }.
// Only provided groups change; invalid ids fall back to the agent default.
app.post('/api/agent-settings', (req, res) => {
  const body = req.body || {};
  const scope = resolveAgentScope(req, res, {
    agentKey: body.agent,
    requireSession: false,
    agentError: agentRequiredError,
  });
  if (!scope) return;
  const { agent, workdir, contextKey } = scope;
  const partial = {};
  for (const group of ['model', 'effort', 'permission']) {
    if (typeof body[group] === 'string') partial[group] = body[group];
  }
  const settings = setSettings(agent.key, contextKey, partial);
  return res.json({ ok: true, agent: agent.key, workdir, settings });
});

// Installed CLI version for the agent (for the model page's version label).
app.get('/api/agent-version', async (req, res) => {
  const agent = getAgent(String(req.query.agent || '').trim());
  if (!agent) {
    return res.status(400).json({ error: 'agent is required' });
  }
  const version = await cliVersion(agent.key);
  return res.json({ ok: true, agent: agent.key, version });
});

// Update the agent's CLI binary so newly shipped models become selectable.
// Runs `<cli> update` (fixed argv); returns the before/after version. Protected
// by the same bearer-token middleware as every other /api/* route.
app.post('/api/agent-update', async (req, res) => {
  const agent = getAgent(String((req.body || {}).agent || '').trim());
  if (!agent) {
    return res.status(400).json({ error: 'agent is required' });
  }
  const cli = CLI[agent.key];
  if (!cli) {
    return res.status(400).json({ error: `no updater for ${agent.key}` });
  }
  const before = await cliVersion(agent.key);
  const result = await runCliCommand(cli.bin, cli.updateArgs, 180000);
  const after = await cliVersion(agent.key);
  return res.json({
    ok: result.ok,
    agent: agent.key,
    before,
    after,
    changed: !!after && after !== before,
    timedOut: result.timedOut,
    output: result.text.slice(0, 4000),
  });
});

// Best-effort login state per agent so the app can warn before sending a
// message. loggedIn is true/false when detectable from on-disk credentials,
// or null when it cannot be determined without running the CLI (e.g. agy).
app.get('/api/auth/status', (_req, res) => {
  res.json({
    agents: listAgents().map((agent) => ({
      key: agent.key,
      label: agent.label,
      loggedIn: authStatus(agent.key),
    })),
  });
});

app.get('/api/tokens', (req, res) => {
  res.json({
    tokens: listTokenSummaries({ currentToken: bearerToken(req) }),
  });
});

app.post('/api/tokens/:id/revoke', (req, res) => {
  const id = String(req.params.id || '').trim();
  const revoked = revokeTokenById(id);
  if (!revoked) {
    return res.status(404).json({ error: 'token not found' });
  }
  res.json({
    token: {
      id: revoked.id || '',
      label: revoked.label || '',
      createdAt: revoked.createdAt || '',
      revoked: true,
      revokedAt: revoked.revokedAt || '',
      current: String(revoked.token || '') === bearerToken(req),
    },
  });
});

app.get('/api/push/config', (_req, res) => {
  res.json({ enabled: push.isEnabled(), publicKey: push.publicKey() });
});

app.post('/api/push/subscribe', (req, res) => {
  const subscription = req.body && req.body.subscription;
  if (!subscription || !subscription.endpoint) {
    return res.status(400).json({ error: 'subscription is required' });
  }
  let workdir = '';
  try {
    workdir = requestWorkdir(req);
  } catch (_err) {
    workdir = '';
  }
  push.addSubscription({
    subscription,
    workdir,
    lang: req.body && req.body.lang,
    categories: pushCategoriesFromBody(req.body),
  });
  res.json({ ok: true });
});

app.post('/api/push/unsubscribe', (req, res) => {
  const endpoint = req.body && req.body.endpoint;
  push.removeSubscription(endpoint);
  res.json({ ok: true });
});

app.post('/api/push/fcm/register', (req, res) => {
  const token = req.body && req.body.token;
  if (!token || typeof token !== 'string') {
    return res.status(400).json({ error: 'token is required' });
  }
  let workdir = '';
  try {
    workdir = requestWorkdir(req);
  } catch (_err) {
    workdir = '';
  }
  fcm.addToken({
    token,
    workdir,
    lang: req.body && req.body.lang,
    categories: pushCategoriesFromBody(req.body),
  });
  return res.json({ ok: true, enabled: fcm.isEnabled() });
});

app.post('/api/push/fcm/unregister', (req, res) => {
  const token = req.body && req.body.token;
  fcm.removeToken(token);
  res.json({ ok: true, enabled: fcm.isEnabled() });
});

app.get('/api/status', (req, res) => {
  res.json({
    ok: true,
    defaultAgent: DEFAULT_AGENT,
    workdir: eventWorkdir(req),
    defaultWorkdir: getDefaultWorkdir(),
    systemUptime: formatUptime(os.uptime()),
    processUptime: formatUptime(process.uptime()),
    agentTimeoutMs: TIMEOUT_MS,
    quotaWatch: ENABLE_QUOTA_WATCH,
    publicBaseUrl: PUBLIC_BASE_URL,
  });
});

app.get('/api/diagnostics', (req, res) => {
  const workdir = eventWorkdir(req);
  res.json(
    buildDiagnostics({
      workdir,
      defaultWorkdir: getDefaultWorkdir(),
      publicBaseUrl: PUBLIC_BASE_URL,
      host: HOST,
      port: PORT,
      quotaWatch: ENABLE_QUOTA_WATCH,
      agentTimeoutMs: TIMEOUT_MS,
      maxUploadBytes: MAX_UPLOAD_BYTES,
      maxDownloadBytes: MAX_DOWNLOAD_BYTES,
      webBuildDir: WEB_BUILD_DIR,
      agents: listAgents(),
      runtime: {
        sseClients: eventClients.size,
        activeRequests: activeRequests.size,
        runningScopes: runningScopes.size,
        queuedScopes: scopeChains.size,
      },
    }),
  );
});

app.get('/api/workdir', (req, res) => {
  try {
    const dir = requestWorkdir(req);
    return res.json({ dir, busy: workdirBusy(dir) });
  } catch (err) {
    return sendWorkdirError(res, err);
  }
});

// Validate (and optionally create) a path the device wants to switch to. With
// per-device workdirs there is no global state to change here: the client
// stores the returned canonical path locally and sends it back via x-workdir.
app.post('/api/workdir', (req, res) => {
  try {
    const result = validateWorkdir(req.body && req.body.path, {
      create: req.body && req.body.create === true,
    });
    return res.json({
      ok: true,
      dir: result.dir,
      created: result.created,
    });
  } catch (err) {
    return sendWorkdirError(res, err);
  }
});

app.get('/api/workdir/browse', (req, res) => {
  try {
    return res.json(
      listAbsoluteDirectory(req.query.path, {
        showHidden: queryBool(req.query.showHidden),
        fallbackDir: eventWorkdir(req),
      }),
    );
  } catch (err) {
    return sendFilesystemError(res, err);
  }
});

app.get('/api/fs/download', async (req, res) => {
  let download;
  try {
    // The unified file browser sends absolute paths (it can reach anywhere up to
    // root); older relative paths stay confined to the workdir. Both enforce the
    // size cap so an oversized transfer is refused before it starts.
    if (req.query.path && path.isAbsolute(String(req.query.path))) {
      download = await prepareDownloadAbsolute(req.query.path, {
        maxBytes: MAX_DOWNLOAD_BYTES,
      });
    } else {
      download = prepareDownload(req.query.path, requestWorkdir(req));
    }
  } catch (err) {
    return sendFilesystemError(res, err);
  }

  if (!download.isDirectory) {
    return res.download(download.target, download.filename, (err) => {
      if (err && !res.headersSent) {
        return sendFilesystemError(res, err);
      }
      return undefined;
    });
  }

  return sendDirectoryZip(download, res);
});

app.post('/api/fs/upload', rawUpload, uploadErrorHandler, async (req, res) => {
  if (Buffer.isBuffer(req.body) && req.body.length > MAX_UPLOAD_BYTES) {
    return res.status(413).json({
      error: 'upload exceeds the size limit',
      code: 'FS_UPLOAD_TOO_LARGE',
    });
  }
  let target;
  try {
    // Absolute target from the unified browser, or workdir-relative (legacy).
    if (req.query.path && path.isAbsolute(String(req.query.path))) {
      target = resolveAbsoluteUploadTarget(req.query.path, req.query.name);
    } else {
      target = resolveUploadTarget(req.query.path, req.query.name, requestWorkdir(req));
    }
    if (fs.existsSync(target.target)) {
      const realTarget = fs.realpathSync(target.target);
      if (
        realTarget !== target.realRoot &&
        !realTarget.startsWith(`${target.realRoot}${path.sep}`)
      ) {
        return res.status(403).json({
          error: 'path is outside the work directory',
          code: 'FS_PATH_OUTSIDE_WORKDIR',
        });
      }
    }
    await fs.promises.writeFile(
      target.target,
      Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0),
    );
    return res.json({
      ok: true,
      entry: uploadedEntry(target.root, target.target),
    });
  } catch (err) {
    return sendFilesystemError(res, err);
  }
});

app.post('/api/chat', async (req, res) => {
  const agentKey = String(req.body.agent || DEFAULT_AGENT).trim();
  const requestId = String(req.body.requestId || randomUUID()).trim();
  const prompt = String(req.body.prompt || '').trim();
  const requestedSessionId = String(req.body.sessionId || '').trim();
  const recordHistory = req.body.recordHistory !== false;
  const deviceId = normalizeDeviceId(req.get('x-device-id'));
  if (!prompt) {
    return res.status(400).json({ error: 'prompt is required' });
  }
  const scope = resolveAgentScope(req, res, {
    agentKey,
    sessionId: requestedSessionId,
    agentError: (key) => ({ status: 400, body: { error: `unknown agent: ${key}` } }),
    beforeWorkdir: () => {
      if (!activeRequests.has(requestId)) return true;
      res.status(409).json({
        error: 'request already running',
        code: 'REQUEST_BUSY',
      });
      return false;
    },
  });
  if (!scope) return;
  const { agent, workdir, contextKey, session: chatSession, scopeKey } = scope;
  touchChatSession(contextKey, chatSession.id);

  const abortController = new AbortController();
  const historyAssistantId = `${requestId}:assistant`;
  const runState = {
    requestId,
    agent,
    session: chatSession,
    deviceId,
    scopeKey,
    scopeWorkdir: workdir,
    recordHistory,
    historyAssistantId,
    cancelled: false,
    cancelEventSent: false,
    abortController,
  };
  activeRequests.set(requestId, runState);
  const responder = createChatResponder({ req, res });

  try {
    await runAgentTurn({
      agent,
      agentKey,
      contextKey,
      dependencies: agentTurnDependencies(),
      deviceId,
      notifyTaskCompletion,
      prompt,
      recordHistory,
      requestId,
      responder,
      runState,
      scopeKey,
      session: chatSession,
      signal: abortController.signal,
      workdir,
    });
  } finally {
    activeRequests.delete(requestId);
  }
});

app.post('/api/chat/cancel', (req, res) => {
  const requestId = String(req.body.requestId || '').trim();
  const deviceId = normalizeDeviceId(req.get('x-device-id'));
  if (!requestId) {
    return res.status(400).json({ error: 'requestId is required' });
  }

  const runState = activeRequests.get(requestId);
  if (!runState) {
    return res.status(404).json({
      error: 'request not found',
      code: 'REQUEST_NOT_FOUND',
    });
  }
  // Shared sessions: any device currently in the same work directory may cancel
  // the turn, not just the device that started it.
  let workdir;
  try {
    workdir = requestWorkdir(req);
  } catch (err) {
    return sendWorkdirError(res, err);
  }
  if (runState.scopeWorkdir && runState.scopeWorkdir !== workdir) {
    return res.status(404).json({
      error: 'request not found',
      code: 'REQUEST_NOT_FOUND',
    });
  }

  runState.cancelled = true;
  if (!runState.cancelEventSent) {
    runState.cancelEventSent = true;
    broadcastScope('agent_cancelled', {
      scopeWorkdir: runState.scopeWorkdir,
      agent: runState.agent,
      session: runState.session,
      requestId,
      deviceId: runState.deviceId,
    });
  }
  runState.abortController.abort();
  return res.json({ ok: true, requestId });
});

app.get('/api/sessions', (req, res) => {
  const agentKey = String(req.query.agent || '').trim();
  const scope = resolveAgentScope(req, res, {
    agentKey,
    requireSession: false,
    agentError: agentRequiredOrUnknownError,
  });
  if (!scope) return;
  const { agent, workdir, contextKey } = scope;
  return res.json({
    ok: true,
    agent: agentPayload(agent),
    workdir,
    ...listChatSessions(contextKey),
  });
});

app.post('/api/sessions', (req, res) => {
  const agentKey = String(req.body.agent || '').trim();
  const scope = resolveAgentScope(req, res, {
    agentKey,
    requireSession: false,
    agentError: agentRequiredOrUnknownError,
  });
  if (!scope) return;
  const { agent, workdir, contextKey } = scope;
  const created = createChatSession(contextKey, req.body.name);
  if (!created) {
    return res.status(409).json({
      error: `session limit reached (max ${MAX_SESSIONS})`,
      code: 'SESSION_LIMIT_REACHED',
    });
  }
  return res.json({
    ok: true,
    agent: agentPayload(agent),
    workdir,
    ...created,
  });
});

app.post('/api/sessions/active', (req, res) => {
  const agentKey = String(req.body.agent || '').trim();
  const sessionId = String(req.body.sessionId || '').trim();
  const scope = resolveAgentScope(req, res, {
    agentKey,
    requireSession: false,
    agentError: agentRequiredOrUnknownError,
    beforeWorkdir: () => {
      if (sessionId) return true;
      res.status(400).json({ error: 'sessionId is required' });
      return false;
    },
  });
  if (!scope) return;
  const { agent, workdir, contextKey } = scope;
  const result = setActiveChatSession(contextKey, sessionId);
  if (!result) {
    return res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
  }
  return res.json({
    ok: true,
    agent: agentPayload(agent),
    workdir,
    ...result,
  });
});

app.post('/api/sessions/delete', (req, res) => {
  const agentKey = String(req.body.agent || '').trim();
  const sessionId = String(req.body.sessionId || '').trim();
  const scope = resolveAgentScope(req, res, {
    agentKey,
    requireSession: false,
    agentError: agentRequiredOrUnknownError,
    beforeWorkdir: () => {
      if (!sessionId) {
        res.status(400).json({ error: 'sessionId is required' });
        return false;
      }
      if (sessionId === LEGACY_SESSION_ID) {
        res.status(400).json({
          error: 'the default session cannot be deleted',
          code: 'SESSION_PROTECTED',
        });
        return false;
      }
      return true;
    },
  });
  if (!scope) return;
  const { agent, workdir, contextKey } = scope;
  const existing = listChatSessions(contextKey).sessions.find(
    (session) => session.id === sessionId,
  );
  if (!existing) {
    return res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
  }
  const scopeKey = scopeKeyFor(agent.key, workdir, sessionId);
  if (runningScopes.has(scopeKey) || scopeChains.has(scopeKey)) {
    return res.status(409).json({
      error: 'session has a running turn',
      code: 'SESSION_BUSY',
    });
  }
  const result = deleteChatSession(contextKey, sessionId);
  clearSession(scopeKey);
  clearHistory(scopeKey);
  return res.json({
    ok: true,
    agent: agentPayload(agent),
    workdir,
    deletedSessionId: sessionId,
    ...result,
  });
});

// Return the stored conversation for this work directory + agent + chat session
// so any device in the same path/session shows the same chat.
app.get('/api/history', (req, res) => {
  const agentKey = String(req.query.agent || '').trim();
  const requestedSessionId = String(req.query.sessionId || '').trim();
  const scope = resolveAgentScope(req, res, {
    agentKey,
    sessionId: requestedSessionId,
    agentError: agentRequiredOrUnknownError,
  });
  if (!scope) return;
  const { agent, workdir, session: chatSession, scopeKey } = scope;
  // Only finalize a streaming bubble as stale when nothing is running OR queued
  // for this scope; a queued turn has a persisted awaiting bubble that is not
  // yet in runningScopes and must not be prematurely marked cancelled.
  if (!runningScopes.has(scopeKey) && !scopeChains.has(scopeKey)) {
    finalizeStaleStreamingHistory(scopeKey);
  }
  return res.json({
    agent: agent.key,
    workdir,
    session: sessionPayload(chatSession),
    messages: readHistory(scopeKey),
  });
});

app.get('/api/history/search', (req, res) => {
  const query = String(req.query.q || '').trim();
  const agentKey = String(req.query.agent || '').trim();
  if (!query) {
    return res.status(400).json({ error: 'q is required' });
  }
  if (agentKey && !getAgent(agentKey)) {
    return res.status(400).json({ error: `unknown agent: ${agentKey}` });
  }
  let workdir;
  try {
    workdir = requestWorkdir(req);
  } catch (err) {
    return sendWorkdirError(res, err);
  }
  const sessionNameFor = (matchAgentKey, sessionId) => {
    const contextKey = sessionContextKeyFor(matchAgentKey, workdir);
    const session = listChatSessions(contextKey).sessions.find(
      (item) => item.id === sessionId,
    );
    return session ? session.name : sessionId;
  };
  const matches = searchHistory({
    workdir,
    query,
    agentKey,
    sessionNameFor,
  });
  return res.json({ workdir, query, matches });
});

app.get('/api/history/export', (req, res) => {
  const agentKey = String(req.query.agent || '').trim();
  const requestedSessionId = String(req.query.sessionId || '').trim();
  const scope = resolveAgentScope(req, res, {
    agentKey,
    sessionId: requestedSessionId,
    agentError: agentRequiredOrUnknownError,
  });
  if (!scope) return;
  const { agent, session: chatSession, scopeKey } = scope;
  if (!runningScopes.has(scopeKey) && !scopeChains.has(scopeKey)) {
    finalizeStaleStreamingHistory(scopeKey);
  }
  const exportedAt = new Date().toISOString();
  const markdown = markdownForConversation({
    agentLabel: agent.label,
    sessionName: chatSession.name,
    messages: readHistory(scopeKey),
    exportedAt,
  });
  const fileName = `${safeDownloadName(agent.key)}-${safeDownloadName(chatSession.name, 'session')}.md`;
  return res.json({
    agent: agent.key,
    session: sessionPayload(chatSession),
    fileName,
    markdown,
  });
});

app.get('/api/usage', async (_req, res) => {
  try {
    const report = await buildUsageReport();
    return res.json(report);
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

app.get('/api/quota-schedules', (req, res) => {
  const workdir = eventWorkdir(req);
  return res.json({ workdir, schedules: listQuotaSchedules({ workdir }) });
});

app.post('/api/quota-schedules', (req, res) => {
  const sourceKey = String(req.body.sourceKey || '').trim();
  const agentKey = String(req.body.agent || req.body.agentKey || '').trim();
  const requestedSessionId = String(req.body.sessionId || '').trim();
  if (!['claude', 'codex'].includes(sourceKey)) {
    return res.status(400).json({
      error: 'sourceKey must be claude or codex',
      code: 'INVALID_QUOTA_SOURCE',
    });
  }
  const scope = resolveAgentScope(req, res, {
    agentKey,
    sessionId: requestedSessionId,
    agentError: agentRequiredOrUnknownError,
  });
  if (!scope) return;
  const { agent, workdir, session: chatSession } = scope;
  try {
    const schedule = createQuotaSchedule({
      sourceKey,
      agentKey: agent.key,
      sessionId: chatSession.id,
      sessionName: chatSession.name,
      workdir,
      prompt: req.body.prompt,
      targetResetsAt: req.body.targetResetsAt,
      replaceExisting: req.body.replaceExisting === true,
    });
    sendEvent('quota_schedule_changed', {
      scopeWorkdir: workdir,
      action: req.body.replaceExisting === true ? 'replace' : 'create',
      schedule,
      createdAt: new Date().toISOString(),
    });
    return res.json({ ok: true, schedule });
  } catch (err) {
    return res.status(err.code === 'SCHEDULE_EXISTS' ? 409 : 400).json({
      error: err.message,
      code: err.code || 'SCHEDULE_CREATE_FAILED',
    });
  }
});

app.post('/api/quota-schedules/cancel', (req, res) => {
  const id = String(req.body.id || '').trim();
  if (!id) {
    return res.status(400).json({ error: 'id is required' });
  }
  try {
    const schedule = cancelQuotaSchedule(id);
    if (!schedule) {
      return res.status(404).json({
        error: 'scheduled message not found',
        code: 'SCHEDULE_NOT_FOUND',
      });
    }
    sendEvent('quota_schedule_changed', {
      scopeWorkdir: schedule.workdir,
      action: 'cancel',
      schedule,
      createdAt: new Date().toISOString(),
    });
    return res.json({ ok: true, schedule });
  } catch (err) {
    return res.status(409).json({
      error: err.message,
      code: err.code || 'SCHEDULE_CANCEL_FAILED',
    });
  }
});

// Clear one chat session's history plus resumable CLI session so the next message
// starts a new machine-side conversation. This does not touch files on disk.
app.post('/api/session/clear', (req, res) => {
  const agentKey = String(req.body.agent || '').trim();
  const requestedSessionId = String(req.body.sessionId || '').trim();
  let workdir;
  try {
    workdir = requestWorkdir(req);
  } catch (err) {
    return sendWorkdirError(res, err);
  }
  if (agentKey) {
    const agent = getAgent(agentKey);
    if (!agent) {
      return res.status(400).json({ error: `unknown agent: ${agentKey}` });
    }
    const contextKey = sessionContextKeyFor(agent.key, workdir);
    const sessions = listChatSessions(contextKey).sessions;
    const chatSession = requestedSessionId
      ? sessions.find((session) => session.id === requestedSessionId)
      : resolveChatSession(contextKey, '');
    if (!chatSession) {
      return res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
    }
    const scopeKey = scopeKeyFor(agent.key, workdir, chatSession.id);
    if (runningScopes.has(scopeKey) || scopeChains.has(scopeKey)) {
      return res.status(409).json({
        error: 'session has a running turn',
        code: 'SESSION_BUSY',
      });
    }
    const cleared = clearSession(scopeKey);
    clearHistory(scopeKey);
    touchChatSession(contextKey, chatSession.id);
    return res.json({
      ok: true,
      agent: agentKey,
      workdir,
      session: sessionPayload(chatSession),
      cleared,
    });
  }
  let cleared = 0;
  for (const agent of listAgents()) {
    const contextKey = sessionContextKeyFor(agent.key, workdir);
    for (const chatSession of listChatSessions(contextKey).sessions) {
      const scopeKey = scopeKeyFor(agent.key, workdir, chatSession.id);
      if (clearSession(scopeKey)) cleared += 1;
      clearHistory(scopeKey);
    }
  }
  return res.json({ ok: true, workdir, cleared });
});

app.get('/api/events', (req, res) => {
  const deviceId = normalizeDeviceId(req.get('x-device-id'));
  // Scope this subscription to the device's current work directory so it only
  // receives chat events for the conversation it is viewing. The client
  // reconnects with a new x-workdir header when the user switches paths.
  const workdir = eventWorkdir(req);
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  const client = { res, deviceId, workdir };
  eventClients.add(client);
  res.write(`event: ready\ndata: ${JSON.stringify({ ok: true })}\n\n`);

  const heartbeat = setInterval(() => {
    res.write(`event: heartbeat\ndata: ${JSON.stringify({ at: new Date().toISOString() })}\n\n`);
  }, 30_000);

  req.on('close', () => {
    clearInterval(heartbeat);
    eventClients.delete(client);
  });
});

// --- Card Mode (additive secondary surface; does not touch chat) ---
app.get('/api/cards', (req, res) => {
  const workdir = eventWorkdir(req);
  return res.json({ workdir, cards: cards.getActiveCards(workdir) });
});

app.post('/api/cards/feedback', (req, res) => {
  const workdir = eventWorkdir(req);
  const cardId = String(req.body.cardId || '').trim();
  const gesture = String(req.body.gesture || '').trim();
  const deferUntil = req.body.deferUntil ? String(req.body.deferUntil) : null;
  if (!cardId || !gesture) {
    return res.status(400).json({ error: 'cardId and gesture are required' });
  }
  if (!cards.applyFeedback(cardId, gesture, deferUntil, workdir)) {
    return res.status(400).json({ error: 'unknown card or gesture' });
  }
  return res.json({ ok: true });
});

app.post('/api/cards/refresh', (req, res) => {
  const workdir = eventWorkdir(req);
  const generated = cards.replaceGeneratedCards(
    generateCardsForWorkdir(workdir),
    workdir,
  );
  return res.json({ workdir, generated });
});

if (fs.existsSync(path.join(WEB_BUILD_DIR, 'index.html'))) {
  app.use(express.static(WEB_BUILD_DIR, {
    etag: true,
    lastModified: true,
    setHeaders(res, filePath) {
      const rel = path.relative(WEB_BUILD_DIR, filePath);
      // CanvasKit is pinned to the Flutter engine revision and is effectively
      // immutable between SDK upgrades; cache the 7MB wasm hard so it downloads
      // once and is then served from the browser cache with no request at all.
      if (rel.split(path.sep)[0] === 'canvaskit') {
        res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
        return;
      }
      // Other files (index.html, *.js, assets) keep their filenames across builds,
      // so allow caching but always revalidate: a matching ETag returns a tiny 304
      // instead of re-sending the bytes. Never `no-store` — that re-downloaded the
      // whole ~11MB bundle on every load, which is what made the web take minutes.
      res.setHeader('Cache-Control', 'no-cache');
    },
  }));
  app.get('*', (req, res) => {
    if (req.path.startsWith('/api/')) {
      return res.status(404).json({ error: 'not found' });
    }
    res.setHeader('Cache-Control', 'no-cache');
    return res.sendFile(path.join(WEB_BUILD_DIR, 'index.html'));
  });
}

app.listen(PORT, HOST, () => {
  console.log(`Relay server listening on http://${HOST}:${PORT}`);
  if (PUBLIC_BASE_URL) {
    console.log(`public tunnel URL: ${PUBLIC_BASE_URL}`);
  }
  console.log(`default workdir: ${getDefaultWorkdir()}`);
  const staleHistoryCount = finalizeAllStaleStreamingHistory();
  if (staleHistoryCount > 0) {
    console.log(`finalized ${staleHistoryCount} stale streaming history item(s)`);
  }
  // Card Mode: seed suggestions once if none are pending yet.
  try {
    const defaultWorkdir = getDefaultWorkdir();
    if (cards.pendingCountForWorkdir(defaultWorkdir) === 0) {
      cards.replaceGeneratedCards(
        generateCardsForWorkdir(defaultWorkdir),
        defaultWorkdir,
      );
    }
  } catch (_err) {
    // Non-fatal; Card Mode is a secondary feature.
  }
  if (fs.existsSync(path.join(WEB_BUILD_DIR, 'index.html'))) {
    console.log(`serving Flutter web from ${WEB_BUILD_DIR}`);
  }
  if (!hasConfiguredToken()) {
    console.warn('No app token is configured. Create a credential before exposing this server.');
  }
  try {
    const recovered = reconcileRunningSchedules();
    if (recovered > 0) {
      console.warn(`Marked ${recovered} interrupted scheduled message(s) as failed.`);
    }
  } catch (err) {
    console.error(`Failed to reconcile scheduled messages: ${err.message}`);
  }
  if (ENABLE_QUOTA_WATCH) {
    startQuotaWatch({
      name: 'app',
      onReset: async (message, info) => {
        sendEvent('quota_reset', {
          message,
          messageZh: info && info.messageZh,
          info,
          createdAt: new Date().toISOString(),
        });
        // Reach offline clients; SSE only covers open app sessions.
        push
          .notify({
            message,
            messageZh: info && info.messageZh,
            category: 'quota',
          })
          .catch((err) => console.warn(`[push] quota_reset: ${err.message}`));
        fcm
          .notify({
            message,
            messageZh: info && info.messageZh,
            category: 'quota',
          })
          .catch((err) => console.warn(`[fcm] quota_reset: ${err.message}`));
        processDueQuotaSchedules(info).catch((err) => {
          console.error(`[quota:${info && info.key}] scheduled message runner failed: ${err.message}`);
        });
      },
    });
  }
});
