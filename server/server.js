'use strict';

require('dotenv').config();

const fs = require('fs');
const os = require('os');
const path = require('path');
const { randomUUID } = require('crypto');
const express = require('express');

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
  getWorkdir,
  inspectWorkdir,
  setWorkdir,
} = require('./lib/workdir');
const { hasConfiguredToken, isTokenAllowed } = require('./lib/tokens');
const { buildUsageReport } = require('./lib/usage');
const { startQuotaWatch } = require('./lib/quota-watch');
const { authStatus } = require('./lib/auth-status');
const {
  readHistory,
  upsertHistoryMessage,
  updateHistoryMessage,
  finalizeStaleStreamingHistory,
  finalizeAllStaleStreamingHistory,
  clearHistory,
} = require('./lib/history');
const cards = require('./lib/cards');
const { generateCardsForAllAgents } = require('./lib/chat-learner');

const PORT = parseInt(process.env.PORT || '8787', 10);
const HOST = process.env.HOST || '127.0.0.1';
const PUBLIC_BASE_URL = (process.env.PUBLIC_BASE_URL || '').replace(/\/+$/, '');
const ENABLE_QUOTA_WATCH = process.env.ENABLE_QUOTA_WATCH !== 'false';
const WEB_BUILD_DIR = path.join(__dirname, '..', 'build', 'web');

const app = express();
const eventClients = new Set();
const activeRequests = new Map();
const runningScopes = new Set();

app.use(express.json({ limit: '16mb' }));
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader(
    'Access-Control-Allow-Headers',
    'Content-Type, Authorization, X-Device-Id',
  );
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

function clearWorkdir() {
  const dir = getWorkdir();
  let count = 0;
  for (const entry of fs.readdirSync(dir)) {
    fs.rmSync(path.join(dir, entry), { recursive: true, force: true });
    count += 1;
  }
  return { dir, count };
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

function sendEvent(type, payload) {
  const packet = `event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`;
  const targetDeviceId = normalizeDeviceId(payload && payload.deviceId);
  for (const client of eventClients) {
    // Targeted events carry a deviceId and are only delivered to that device.
    // Broadcast events without a deviceId, such as quota_reset, reach everyone.
    if (targetDeviceId && client.deviceId !== targetDeviceId) {
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

function sessionKeyFor(agentKey, deviceId) {
  return deviceId ? `${deviceId}:${agentKey}` : agentKey;
}

function agentPayload(agent) {
  return { key: agent.key, label: agent.label };
}

function emitAgentEvent(type, { requestId, agent, deviceId, ...payload }) {
  sendEvent(type, {
    requestId,
    deviceId,
    agent: agentPayload(agent),
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

async function streamTextFallback(res, requestId, agent, deviceId, text) {
  const value = String(text || '');
  if (!value) return;
  const chunks = value.match(/[\s\S]{1,64}/g) || [];
  for (const chunk of chunks) {
    writeStreamEvent(res, 'agent_delta', {
      requestId,
      deviceId,
      agent: agentPayload(agent),
      text: chunk,
      createdAt: new Date().toISOString(),
    });
    await sleep(18);
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

app.get('/api/status', (_req, res) => {
  res.json({
    ok: true,
    defaultAgent: DEFAULT_AGENT,
    workdir: getWorkdir(),
    systemUptime: formatUptime(os.uptime()),
    processUptime: formatUptime(process.uptime()),
    agentTimeoutMs: TIMEOUT_MS,
    quotaWatch: ENABLE_QUOTA_WATCH,
    publicBaseUrl: PUBLIC_BASE_URL,
  });
});

app.get('/api/workdir', (_req, res) => {
  try {
    return res.json({
      dir: getWorkdir(),
      busy: activeRequests.size > 0 || runningScopes.size > 0,
    });
  } catch (err) {
    return sendWorkdirError(res, err);
  }
});

app.post('/api/workdir/check', (req, res) => {
  try {
    const info = inspectWorkdir(req.body && req.body.path);
    return res.json(info);
  } catch (err) {
    return sendWorkdirError(res, err);
  }
});

app.post('/api/workdir', (req, res) => {
  if (activeRequests.size > 0 || runningScopes.size > 0) {
    return res.status(409).json({
      error: 'agent task is running',
      code: 'WORKDIR_BUSY',
    });
  }
  try {
    const result = setWorkdir(req.body && req.body.path, {
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

app.post('/api/chat', async (req, res) => {
  const agentKey = String(req.body.agent || DEFAULT_AGENT).trim();
  const requestId = String(req.body.requestId || randomUUID()).trim();
  const prompt = String(req.body.prompt || '').trim();
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

  const scopeKey = sessionKeyFor(agent.key, deviceId);
  if (runningScopes.has(scopeKey)) {
    return res.status(409).json({
      error: 'agent is already handling a message',
      code: 'AGENT_BUSY',
    });
  }

  const abortController = new AbortController();
  const createdAt = new Date().toISOString();
  const historyUserId = `${requestId}:user`;
  const historyAssistantId = `${requestId}:assistant`;
  const baseHistoryMetadata = {
    requestId,
    agentKey: agent.key,
    agentLabel: agent.label,
  };
  const runState = {
    requestId,
    agent,
    deviceId,
    scopeKey,
    recordHistory,
    historyAssistantId,
    cancelled: false,
    cancelEventSent: false,
    abortController,
  };
  activeRequests.set(requestId, runState);
  runningScopes.add(scopeKey);

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
      const payload = { requestId, agent, deviceId, line };
      if (streaming) {
        writeStreamEvent(res, 'agent_progress', {
          requestId,
          deviceId,
          agent: agentPayload(agent),
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
      const payload = { requestId, agent, deviceId, text };
      if (streaming) {
        writeStreamEvent(res, 'agent_delta', {
          requestId,
          deviceId,
          agent: agentPayload(agent),
          text,
          createdAt: new Date().toISOString(),
        });
      } else {
        emitAgentEvent('agent_delta', payload);
      }
    }
  };

  try {
    if (!streaming) {
      emitAgentEvent('agent_start', {
        requestId,
        agent,
        deviceId,
      });
    }
    const content = await runAgent(agentKey, prompt, emitRunEvent, {
      sessionKey: scopeKey,
      signal: abortController.signal,
    });
    if (streaming && !streamedText.trim()) {
      await streamTextFallback(res, requestId, agent, deviceId, content);
    }
    if (!streaming) {
      emitAgentEvent('agent_done', {
        requestId,
        agent,
        deviceId,
      });
    }
    finalizeAssistantHistory(content);
    const completedAt = new Date().toISOString();
    const reply = {
      requestId,
      agent: agentPayload(agent),
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
        if (!streaming) {
          emitAgentEvent('agent_cancelled', {
            requestId,
            agent,
            deviceId,
          });
        }
      }
      if (streaming) {
        writeStreamEvent(res, 'agent_cancelled', {
          requestId,
          deviceId,
          agent: agentPayload(agent),
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
      if (streaming) {
        writeStreamEvent(res, 'agent_error', {
          requestId,
          deviceId,
          agent: agentPayload(agent),
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
    if (streaming) {
      writeStreamEvent(res, 'agent_error', {
        requestId,
        deviceId,
        agent: agentPayload(agent),
        error: errorMessage,
        code: err.code,
        createdAt: new Date().toISOString(),
      });
      endStream(res);
      return;
    }
    emitAgentEvent('agent_error', {
      requestId,
      agent,
      deviceId,
      error: errorMessage,
    });
    return res.status(500).json({ error: errorMessage });
  } finally {
    activeRequests.delete(requestId);
    runningScopes.delete(scopeKey);
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
  if (deviceId && runState.deviceId && deviceId !== runState.deviceId) {
    return res.status(404).json({
      error: 'request not found',
      code: 'REQUEST_NOT_FOUND',
    });
  }

  runState.cancelled = true;
  if (!runState.cancelEventSent) {
    runState.cancelEventSent = true;
    emitAgentEvent('agent_cancelled', {
      requestId,
      agent: runState.agent,
      deviceId: runState.deviceId,
    });
  }
  runState.abortController.abort();
  return res.json({ ok: true, requestId });
});

// Return the stored conversation for this device + agent so the app can show
// the previous chat on reopen without persisting anything locally.
app.get('/api/history', (req, res) => {
  const agentKey = String(req.query.agent || '').trim();
  const deviceId = normalizeDeviceId(req.get('x-device-id'));
  if (!agentKey) {
    return res.status(400).json({ error: 'agent is required' });
  }
  const agent = getAgent(agentKey);
  if (!agent) {
    return res.status(400).json({ error: `unknown agent: ${agentKey}` });
  }
  const scopeKey = sessionKeyFor(agent.key, deviceId);
  if (!runningScopes.has(scopeKey)) {
    finalizeStaleStreamingHistory(scopeKey);
  }
  return res.json({
    agent: agent.key,
    deviceId,
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

// Clear one agent's persistent session so the next message starts a new
// machine-side conversation. Without an agent, clear every agent for the
// current device. This does not touch files in the work directory.
app.post('/api/session/clear', (req, res) => {
  const agentKey = String(req.body.agent || '').trim();
  const deviceId = normalizeDeviceId(req.get('x-device-id'));
  if (agentKey) {
    const agent = getAgent(agentKey);
    if (!agent) {
      return res.status(400).json({ error: `unknown agent: ${agentKey}` });
    }
    const sessionKey = sessionKeyFor(agent.key, deviceId);
    const cleared = clearSession(sessionKey);
    clearHistory(sessionKey);
    return res.json({ ok: true, agent: agentKey, deviceId, cleared });
  }
  let cleared = 0;
  for (const agent of listAgents()) {
    const sessionKey = sessionKeyFor(agent.key, deviceId);
    if (clearSession(sessionKey)) cleared += 1;
    clearHistory(sessionKey);
  }
  return res.json({ ok: true, deviceId, cleared });
});

app.post('/api/workdir/reset', (_req, res) => {
  try {
    const result = clearWorkdir();
    return res.json(result);
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

app.get('/api/events', (req, res) => {
  const deviceId = normalizeDeviceId(req.get('x-device-id'));
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  const client = { res, deviceId };
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
  app.use(express.static(WEB_BUILD_DIR));
  app.get('*', (req, res) => {
    if (req.path.startsWith('/api/')) {
      return res.status(404).json({ error: 'not found' });
    }
    return res.sendFile(path.join(WEB_BUILD_DIR, 'index.html'));
  });
}

app.listen(PORT, HOST, () => {
  console.log(`AgentDeck server listening on http://${HOST}:${PORT}`);
  if (PUBLIC_BASE_URL) {
    console.log(`public tunnel URL: ${PUBLIC_BASE_URL}`);
  }
  console.log(`workdir: ${getWorkdir()}`);
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
      },
    });
  }
});
