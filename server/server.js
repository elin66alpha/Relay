'use strict';

require('dotenv').config();

const fs = require('fs');
const os = require('os');
const path = require('path');
const { randomUUID } = require('crypto');
const express = require('express');

const {
  AgentCancelledError,
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
const { SttError, transcribeAudio } = require('./lib/stt');

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

function sendSttError(res, err) {
  if (err instanceof SttError) {
    return res.status(err.status || 400).json({
      error: err.message,
      code: err.code,
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

app.get('/api/health', (_req, res) => {
  res.json({ ok: true, time: new Date().toISOString() });
});

app.get('/api/agents', (_req, res) => {
  res.json({ defaultAgent: DEFAULT_AGENT, agents: listAgents() });
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
  const runState = {
    requestId,
    agent,
    deviceId,
    scopeKey,
    cancelled: false,
    cancelEventSent: false,
    abortController,
  };
  activeRequests.set(requestId, runState);
  runningScopes.add(scopeKey);

  try {
    emitAgentEvent('agent_start', {
      requestId,
      agent,
      deviceId,
    });
    const content = await runAgent(
      agentKey,
      prompt,
      (event) => {
        if (!event || event.type === 'progress') {
          const line = event && event.line ? String(event.line) : '';
          if (!line) return;
          emitAgentEvent('agent_progress', {
            requestId,
            agent,
            deviceId,
            line,
          });
          return;
        }
        if (event.type === 'delta') {
          const text = String(event.text || '');
          if (!text) return;
          emitAgentEvent('agent_delta', {
            requestId,
            agent,
            deviceId,
            text,
          });
        }
      },
      {
        sessionKey: scopeKey,
        signal: abortController.signal,
      },
    );
    emitAgentEvent('agent_done', {
      requestId,
      agent,
      deviceId,
    });
    return res.json({
      requestId,
      agent: agentPayload(agent),
      message: {
        role: 'assistant',
        content,
        createdAt: new Date().toISOString(),
      },
    });
  } catch (err) {
    if (err instanceof AgentCancelledError || err.code === 'AGENT_CANCELLED') {
      if (!runState.cancelEventSent) {
        runState.cancelEventSent = true;
        emitAgentEvent('agent_cancelled', {
          requestId,
          agent,
          deviceId,
        });
      }
      return res.status(499).json({
        error: 'request cancelled',
        code: 'AGENT_CANCELLED',
      });
    }

    emitAgentEvent('agent_error', {
      requestId,
      agent,
      deviceId,
      error: err.message,
    });
    return res.status(500).json({ error: err.message });
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

app.get('/api/usage', async (_req, res) => {
  try {
    const report = await buildUsageReport();
    return res.json(report);
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

app.post('/api/stt', async (req, res) => {
  try {
    const audioBase64 = String((req.body && req.body.audioBase64) || '').trim();
    if (!audioBase64) {
      throw new SttError('audioBase64 is required', {
        code: 'STT_AUDIO_REQUIRED',
      });
    }
    const result = await transcribeAudio({
      buffer: Buffer.from(audioBase64, 'base64'),
      mimeType: String((req.body && req.body.mimeType) || 'audio/mp4'),
      language: String((req.body && req.body.language) || 'auto'),
    });
    return res.json({
      text: result.text,
      model: result.model,
      language: result.language,
      createdAt: new Date().toISOString(),
    });
  } catch (err) {
    return sendSttError(res, err);
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
    return res.json({ ok: true, agent: agentKey, deviceId, cleared });
  }
  let cleared = 0;
  for (const agent of listAgents()) {
    if (clearSession(sessionKeyFor(agent.key, deviceId))) cleared += 1;
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
