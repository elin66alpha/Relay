'use strict';

require('dotenv').config();

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const { randomUUID } = require('crypto');
const express = require('express');
const compression = require('compression');

const {
  AgentCancelledError,
  AgentAuthError,
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
const { hasConfiguredToken, isTokenAllowed } = require('./lib/tokens');
const { buildUsageReport } = require('./lib/usage');
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
const { generateCardsForAllAgents } = require('./lib/chat-learner');

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

function cleanupTempZip(zipPath) {
  fs.unlink(zipPath, () => {
    fs.rm(path.dirname(zipPath), { recursive: true, force: true }, () => {});
  });
}

function sendWindowsDirectoryZip(download, res) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agentdeck-zip-'));
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

function sessionPayload(session) {
  return session ? { id: session.id, name: session.name } : null;
}

// The work directory for a request: the device's x-workdir header, or the
// default for a device that has not chosen one yet. The path is created if
// missing. Throws WorkdirError for an invalid header, handled by the caller.
function requestWorkdir(req) {
  return resolveRequestWorkdir(req.get('x-workdir'));
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

function agentPayload(agent) {
  return { key: agent.key, label: agent.label };
}

function emitAgentEvent(type, { requestId, agent, session, deviceId, ...payload }) {
  sendEvent(type, {
    requestId,
    deviceId,
    agent: agentPayload(agent),
    ...(session ? { session: sessionPayload(session) } : {}),
    createdAt: new Date().toISOString(),
    ...payload,
  });
}

function wantsChatStream(req) {
  return String(req.get('accept') || '')
    .toLowerCase()
    .includes('text/event-stream');
}

function writeStreamEvent(res, type, payload) {
  if (res.destroyed || res.writableEnded) return;
  try {
    res.write(`event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`);
  } catch (_err) {
    // The client may have closed the app/web tab while the CLI keeps running.
  }
}

function endStream(res) {
  if (res.destroyed || res.writableEnded) return;
  try {
    res.end();
  } catch (_err) {
    // The request can already be gone; the server-side run still finishes.
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function streamTextFallback(res, requestId, agent, session, deviceId, text) {
  const value = String(text || '');
  if (!value) return;
  const chunks = value.match(/[\s\S]{1,64}/g) || [];
  for (const chunk of chunks) {
    writeStreamEvent(res, 'agent_delta', {
      requestId,
      deviceId,
      agent: agentPayload(agent),
      session: sessionPayload(session),
      text: chunk,
      createdAt: new Date().toISOString(),
    });
    await sleep(18);
  }
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
  const createdAt = new Date().toISOString();
  const historyUserId = `${requestId}:user`;
  const historyAssistantId = `${requestId}:assistant`;
  const baseHistoryMetadata = {
    requestId,
    agentKey: agent.key,
    agentLabel: agent.label,
    sessionId: chatSession.id,
    sessionName: chatSession.name,
    scheduledQuotaMessageId: schedule.id,
    quotaSourceKey: schedule.sourceKey,
  };

  upsertHistoryMessage(scopeKey, {
    id: historyUserId,
    role: 'user',
    content: schedule.prompt,
    agent: agent.key,
    createdAt,
    metadata: baseHistoryMetadata,
  });
  upsertHistoryMessage(scopeKey, {
    id: historyAssistantId,
    role: 'assistant',
    content: '',
    agent: agent.key,
    createdAt,
    metadata: {
      ...baseHistoryMetadata,
      streaming: true,
      awaitingFirstToken: true,
      progressLines: ['Scheduled after quota reset.'],
    },
  });

  const updateAssistantHistory = (updater) => {
    updateHistoryMessage(scopeKey, historyAssistantId, (message) => {
      const currentMetadata =
        message &&
        typeof message.metadata === 'object' &&
        !Array.isArray(message.metadata)
          ? message.metadata
          : {};
      return updater({
        ...message,
        content: typeof message.content === 'string' ? message.content : '',
        metadata: currentMetadata,
      });
    });
  };

  const persistProgressLine = (line) => {
    updateAssistantHistory((message) => {
      const lines = Array.isArray(message.metadata.progressLines)
        ? message.metadata.progressLines.filter((item) => typeof item === 'string')
        : [];
      if (lines.length === 0 || lines[lines.length - 1] !== line) {
        lines.push(line);
      }
      while (lines.length > 6) lines.shift();
      return {
        ...message,
        updatedAt: new Date().toISOString(),
        metadata: {
          ...message.metadata,
          ...baseHistoryMetadata,
          streaming: true,
          progressLines: lines,
        },
      };
    });
  };

  const persistDelta = (text) => {
    updateAssistantHistory((message) => ({
      ...message,
      content: `${message.content}${text}`,
      updatedAt: new Date().toISOString(),
      metadata: {
        ...message.metadata,
        ...baseHistoryMetadata,
        streaming: true,
        awaitingFirstToken: false,
      },
    }));
  };

  const finalizeAssistantHistory = (content, metadata = {}) => {
    updateAssistantHistory((message) => ({
      ...message,
      content,
      updatedAt: new Date().toISOString(),
      metadata: {
        ...message.metadata,
        ...baseHistoryMetadata,
        ...metadata,
        streaming: false,
        awaitingFirstToken: false,
        progressLines: [],
      },
    }));
  };

  let streamedText = '';
  const emitRunEvent = (event) => {
    if (!event || event.type === 'progress') {
      const line = event && event.line ? String(event.line) : '';
      if (!line) return;
      persistProgressLine(line);
      broadcastScope('agent_progress', {
        scopeWorkdir: schedule.workdir,
        agent,
        session: chatSession,
        requestId,
        deviceId,
        line,
      });
      return;
    }
    if (event.type === 'delta') {
      const text = String(event.text || '');
      if (!text) return;
      streamedText += text;
      persistDelta(text);
      broadcastScope('agent_delta', {
        scopeWorkdir: schedule.workdir,
        agent,
        session: chatSession,
        requestId,
        deviceId,
        text,
      });
    }
  };

  broadcastScope('agent_start', {
    scopeWorkdir: schedule.workdir,
    agent,
    session: chatSession,
    requestId,
    deviceId,
  });
  if (runningScopes.has(scopeKey) || scopeChains.has(scopeKey)) {
    broadcastScope('agent_queued', {
      scopeWorkdir: schedule.workdir,
      agent,
      session: chatSession,
      requestId,
      deviceId,
    });
  }

  try {
    const content = await enqueueScope(scopeKey, async () => {
      runningScopes.add(scopeKey);
      try {
        return await runAgent(agent.key, schedule.prompt, emitRunEvent, {
          sessionKey: scopeKey,
          workdir: schedule.workdir,
        });
      } finally {
        runningScopes.delete(scopeKey);
      }
    });
    const finalContent = String(content || streamedText || '').trim();
    touchChatSession(contextKey, chatSession.id);
    finalizeAssistantHistory(finalContent);
    markQuotaScheduleSent(schedule.id);
    broadcastScope('agent_done', {
      scopeWorkdir: schedule.workdir,
      agent,
      session: chatSession,
      requestId,
      deviceId,
    });
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
  } catch (err) {
    const errorMessage =
      err instanceof AgentAuthError || err.code === 'NOT_LOGGED_IN'
        ? `${agent.label} is not logged in on the backend host. Log in there, then try again.`
        : err.message || 'scheduled message failed';
    finalizeAssistantHistory(errorMessage, {
      errorCode: err.code || 'SCHEDULED_AGENT_ERROR',
    });
    markQuotaScheduleFailed(schedule.id, errorMessage);
    broadcastScope('agent_error', {
      scopeWorkdir: schedule.workdir,
      agent,
      session: chatSession,
      requestId,
      deviceId,
      error: errorMessage,
      code: err.code,
    });
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
  }
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
  const agent = getAgent(agentKey);
  if (!agent) {
    return res.status(400).json({ error: `unknown agent: ${agentKey}` });
  }
  if (activeRequests.has(requestId)) {
    return res.status(409).json({
      error: 'request already running',
      code: 'REQUEST_BUSY',
    });
  }

  let workdir;
  try {
    workdir = requestWorkdir(req);
  } catch (err) {
    return sendWorkdirError(res, err);
  }
  // Session = workdir + agent + chat session. Concurrent turns on the same
  // session are serialized (see enqueueScope below) rather than rejected.
  const contextKey = sessionContextKeyFor(agent.key, workdir);
  const chatSession = resolveChatSession(contextKey, requestedSessionId);
  if (!chatSession) {
    return res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
  }
  const scopeKey = scopeKeyFor(agent.key, workdir, chatSession.id);
  touchChatSession(contextKey, chatSession.id);

  const abortController = new AbortController();
  const createdAt = new Date().toISOString();
  const historyUserId = `${requestId}:user`;
  const historyAssistantId = `${requestId}:assistant`;
  const baseHistoryMetadata = {
    requestId,
    agentKey: agent.key,
    agentLabel: agent.label,
    sessionId: chatSession.id,
    sessionName: chatSession.name,
  };
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

  const streaming = wantsChatStream(req);
  let streamedText = '';

  if (recordHistory) {
    upsertHistoryMessage(scopeKey, {
      id: historyUserId,
      role: 'user',
      content: prompt,
      agent: agent.key,
      createdAt,
      metadata: baseHistoryMetadata,
    });
    upsertHistoryMessage(scopeKey, {
      id: historyAssistantId,
      role: 'assistant',
      content: '',
      agent: agent.key,
      createdAt,
      metadata: {
        ...baseHistoryMetadata,
        streaming: true,
        awaitingFirstToken: true,
        progressLines: [],
      },
    });
  }

  const updateAssistantHistory = (updater) => {
    if (!recordHistory) return;
    updateHistoryMessage(scopeKey, historyAssistantId, (message) => {
      const currentMetadata =
        message &&
        typeof message.metadata === 'object' &&
        !Array.isArray(message.metadata)
          ? message.metadata
          : {};
      return updater({
        ...message,
        content: typeof message.content === 'string' ? message.content : '',
        metadata: currentMetadata,
      });
    });
  };

  const persistProgressLine = (line) => {
    updateAssistantHistory((message) => {
      const lines = Array.isArray(message.metadata.progressLines)
        ? message.metadata.progressLines.filter(
            (item) => typeof item === 'string',
          )
        : [];
      if (lines.length === 0 || lines[lines.length - 1] !== line) {
        lines.push(line);
      }
      while (lines.length > 6) lines.shift();
      return {
        ...message,
        updatedAt: new Date().toISOString(),
        metadata: {
          ...message.metadata,
          ...baseHistoryMetadata,
          streaming: true,
          progressLines: lines,
        },
      };
    });
  };

  const persistDelta = (text) => {
    updateAssistantHistory((message) => ({
      ...message,
      content: `${message.content}${text}`,
      updatedAt: new Date().toISOString(),
      metadata: {
        ...message.metadata,
        ...baseHistoryMetadata,
        streaming: true,
        awaitingFirstToken: false,
      },
    }));
  };

  const finalizeAssistantHistory = (content, metadata = {}) => {
    updateAssistantHistory((message) => ({
      ...message,
      content,
      updatedAt: new Date().toISOString(),
      metadata: {
        ...message.metadata,
        ...baseHistoryMetadata,
        ...metadata,
        streaming: false,
        awaitingFirstToken: false,
        progressLines: [],
      },
    }));
  };

  if (streaming) {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
    });
    writeStreamEvent(res, 'ready', { ok: true, requestId });
  }

  const emitRunEvent = (event) => {
    if (!event || event.type === 'progress') {
      const line = event && event.line ? String(event.line) : '';
      if (!line) return;
      persistProgressLine(line);
      const payload = {
        scopeWorkdir: workdir,
        requestId,
        agent,
        session: chatSession,
        deviceId,
        line,
      };
      if (streaming) {
        writeStreamEvent(res, 'agent_progress', {
          requestId,
          deviceId,
          agent: agentPayload(agent),
          session: sessionPayload(chatSession),
          line,
          createdAt: new Date().toISOString(),
        });
      } else {
        emitAgentEvent('agent_progress', payload);
      }
      return;
    }
    if (event.type === 'delta') {
      const text = String(event.text || '');
      if (!text) return;
      streamedText += text;
      persistDelta(text);
      const payload = {
        scopeWorkdir: workdir,
        requestId,
        agent,
        session: chatSession,
        deviceId,
        text,
      };
      if (streaming) {
        writeStreamEvent(res, 'agent_delta', {
          requestId,
          deviceId,
          agent: agentPayload(agent),
          session: sessionPayload(chatSession),
          text,
          createdAt: new Date().toISOString(),
        });
      } else {
        emitAgentEvent('agent_delta', payload);
      }
    }
  };

  // Other devices in this workdir learn a turn started and begin mirroring from
  // persisted history. The originator ignores its own requestId. If the scope is
  // already busy this turn will queue behind the in-flight one.
  broadcastScope('agent_start', {
    scopeWorkdir: workdir,
    agent,
    session: chatSession,
    requestId,
    deviceId,
  });
  const willQueue = runningScopes.has(scopeKey) || scopeChains.has(scopeKey);
  if (willQueue) {
    broadcastScope('agent_queued', {
      scopeWorkdir: workdir,
      agent,
      session: chatSession,
      requestId,
      deviceId,
    });
    if (streaming) {
      writeStreamEvent(res, 'agent_queued', {
        requestId,
        deviceId,
        agent: agentPayload(agent),
        session: sessionPayload(chatSession),
        createdAt: new Date().toISOString(),
      });
    }
  }

  try {
    const content = await enqueueScope(scopeKey, async () => {
      // The turn may have been cancelled while waiting its turn in the queue.
      if (runState.cancelled) throw new AgentCancelledError();
      runningScopes.add(scopeKey);
      try {
        return await runAgent(agentKey, prompt, emitRunEvent, {
          sessionKey: scopeKey,
          signal: abortController.signal,
          workdir,
        });
      } finally {
        runningScopes.delete(scopeKey);
      }
    });
    if (streaming && !streamedText.trim()) {
      await streamTextFallback(res, requestId, agent, chatSession, deviceId, content);
    }
    touchChatSession(contextKey, chatSession.id);
    broadcastScope('agent_done', {
      scopeWorkdir: workdir,
      agent,
      session: chatSession,
      requestId,
      deviceId,
    });
    finalizeAssistantHistory(content);
    const completedAt = new Date().toISOString();
    const reply = {
      requestId,
      agent: agentPayload(agent),
      session: sessionPayload(chatSession),
      message: {
        role: 'assistant',
        content,
        createdAt: completedAt,
      },
    };
    if (streaming) {
      writeStreamEvent(res, 'agent_done', reply);
      endStream(res);
      return;
    }
    return res.json(reply);
  } catch (err) {
    if (err instanceof AgentCancelledError || err.code === 'AGENT_CANCELLED') {
      finalizeAssistantHistory(streamedText, { cancelled: true });
      if (!runState.cancelEventSent) {
        runState.cancelEventSent = true;
        broadcastScope('agent_cancelled', {
          scopeWorkdir: workdir,
          agent,
          session: chatSession,
          requestId,
          deviceId,
        });
      }
      if (streaming) {
        writeStreamEvent(res, 'agent_cancelled', {
          requestId,
          deviceId,
          agent: agentPayload(agent),
          session: sessionPayload(chatSession),
          createdAt: new Date().toISOString(),
        });
        endStream(res);
        return;
      }
      return res.status(499).json({
        error: 'request cancelled',
        code: 'AGENT_CANCELLED',
      });
    }

    // Agent CLI has no logged-in account: surface a real, actionable state
    // instead of leaving the persisted in-flight bubble stuck forever.
    if (err instanceof AgentAuthError || err.code === 'NOT_LOGGED_IN') {
      const message =
        `${agentPayload(agent).label} is not logged in on the backend host. ` +
        'Log in there, then try again.';
      finalizeAssistantHistory(message, { errorCode: 'NOT_LOGGED_IN' });
      broadcastScope('agent_error', {
        scopeWorkdir: workdir,
        agent,
        session: chatSession,
        requestId,
        deviceId,
        error: message,
        code: 'NOT_LOGGED_IN',
      });
      if (streaming) {
        writeStreamEvent(res, 'agent_error', {
          requestId,
          deviceId,
          agent: agentPayload(agent),
          session: sessionPayload(chatSession),
          error: message,
          code: 'NOT_LOGGED_IN',
          createdAt: new Date().toISOString(),
        });
        endStream(res);
        return;
      }
      // 424 Failed Dependency: not 401 (reserved for an invalid device token)
      // and not 503 (TOKEN_NOT_CONFIGURED). Clients branch on the code field.
      return res.status(424).json({
        error: message,
        code: 'NOT_LOGGED_IN',
        agent: agent.key,
      });
    }

    const errorMessage = err.message || 'agent request failed';
    finalizeAssistantHistory(errorMessage, {
      errorCode: err.code || 'AGENT_ERROR',
    });
    broadcastScope('agent_error', {
      scopeWorkdir: workdir,
      agent,
      session: chatSession,
      requestId,
      deviceId,
      error: errorMessage,
      code: err.code,
    });
    if (streaming) {
      writeStreamEvent(res, 'agent_error', {
        requestId,
        deviceId,
        agent: agentPayload(agent),
        session: sessionPayload(chatSession),
        error: errorMessage,
        code: err.code,
        createdAt: new Date().toISOString(),
      });
      endStream(res);
      return;
    }
    return res.status(500).json({ error: errorMessage });
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
  const agent = getAgent(agentKey);
  if (!agent) {
    return res.status(400).json({ error: agentKey ? `unknown agent: ${agentKey}` : 'agent is required' });
  }
  let workdir;
  try {
    workdir = requestWorkdir(req);
  } catch (err) {
    return sendWorkdirError(res, err);
  }
  const contextKey = sessionContextKeyFor(agent.key, workdir);
  return res.json({
    ok: true,
    agent: agentPayload(agent),
    workdir,
    ...listChatSessions(contextKey),
  });
});

app.post('/api/sessions', (req, res) => {
  const agentKey = String(req.body.agent || '').trim();
  const agent = getAgent(agentKey);
  if (!agent) {
    return res.status(400).json({ error: agentKey ? `unknown agent: ${agentKey}` : 'agent is required' });
  }
  let workdir;
  try {
    workdir = requestWorkdir(req);
  } catch (err) {
    return sendWorkdirError(res, err);
  }
  const contextKey = sessionContextKeyFor(agent.key, workdir);
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
  const agent = getAgent(agentKey);
  if (!agent) {
    return res.status(400).json({ error: agentKey ? `unknown agent: ${agentKey}` : 'agent is required' });
  }
  if (!sessionId) {
    return res.status(400).json({ error: 'sessionId is required' });
  }
  let workdir;
  try {
    workdir = requestWorkdir(req);
  } catch (err) {
    return sendWorkdirError(res, err);
  }
  const contextKey = sessionContextKeyFor(agent.key, workdir);
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
  const agent = getAgent(agentKey);
  if (!agent) {
    return res.status(400).json({ error: agentKey ? `unknown agent: ${agentKey}` : 'agent is required' });
  }
  if (!sessionId) {
    return res.status(400).json({ error: 'sessionId is required' });
  }
  if (sessionId === LEGACY_SESSION_ID) {
    return res.status(400).json({
      error: 'the default session cannot be deleted',
      code: 'SESSION_PROTECTED',
    });
  }
  let workdir;
  try {
    workdir = requestWorkdir(req);
  } catch (err) {
    return sendWorkdirError(res, err);
  }
  const contextKey = sessionContextKeyFor(agent.key, workdir);
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
  if (!agentKey) {
    return res.status(400).json({ error: 'agent is required' });
  }
  const agent = getAgent(agentKey);
  if (!agent) {
    return res.status(400).json({ error: `unknown agent: ${agentKey}` });
  }
  let workdir;
  try {
    workdir = requestWorkdir(req);
  } catch (err) {
    return sendWorkdirError(res, err);
  }
  const contextKey = sessionContextKeyFor(agent.key, workdir);
  const chatSession = resolveChatSession(contextKey, requestedSessionId);
  if (!chatSession) {
    return res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
  }
  const scopeKey = scopeKeyFor(agent.key, workdir, chatSession.id);
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
  const agent = getAgent(agentKey);
  if (!['claude', 'codex'].includes(sourceKey)) {
    return res.status(400).json({
      error: 'sourceKey must be claude or codex',
      code: 'INVALID_QUOTA_SOURCE',
    });
  }
  if (!agent) {
    return res.status(400).json({
      error: agentKey ? `unknown agent: ${agentKey}` : 'agent is required',
    });
  }
  let workdir;
  try {
    workdir = requestWorkdir(req);
  } catch (err) {
    return sendWorkdirError(res, err);
  }
  const contextKey = sessionContextKeyFor(agent.key, workdir);
  const chatSession = resolveChatSession(contextKey, requestedSessionId);
  if (!chatSession) {
    return res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
  }
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
app.get('/api/cards', (_req, res) => {
  return res.json({ cards: cards.getActiveCards() });
});

app.post('/api/cards/feedback', (req, res) => {
  const cardId = String(req.body.cardId || '').trim();
  const gesture = String(req.body.gesture || '').trim();
  const deferUntil = req.body.deferUntil ? String(req.body.deferUntil) : null;
  if (!cardId || !gesture) {
    return res.status(400).json({ error: 'cardId and gesture are required' });
  }
  if (!cards.applyFeedback(cardId, gesture, deferUntil)) {
    return res.status(400).json({ error: 'unknown card or gesture' });
  }
  return res.json({ ok: true });
});

app.post('/api/cards/refresh', (_req, res) => {
  const generated = cards.replaceGeneratedCards(generateCardsForAllAgents());
  return res.json({ generated });
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
  console.log(`AgentDeck server listening on http://${HOST}:${PORT}`);
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
    if (cards.pendingCount() === 0) {
      cards.replaceGeneratedCards(generateCardsForAllAgents());
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
        processDueQuotaSchedules(info).catch((err) => {
          console.error(`[quota:${info && info.key}] scheduled message runner failed: ${err.message}`);
        });
      },
    });
  }
});
