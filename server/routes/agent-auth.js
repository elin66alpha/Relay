'use strict';

const express = require('express');

const {
  clearAgentStatusCache,
  getAgentStatuses,
} = require('../lib/agent-status');
const { createAgentLoginManager } = require('../lib/agent-login');

function writeStreamEvent(res, type, payload) {
  if (res.destroyed || res.writableEnded) return;
  res.write(`event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`);
}

function sendError(res, status, err) {
  return res.status(status).json({
    error: err.message || 'request failed',
    code: err.code || 'AGENT_AUTH_ERROR',
  });
}

module.exports = function createAgentAuthRouter(ctx = {}) {
  const router = express.Router();
  const getAgent = ctx.getAgent || (() => null);
  const loginManager = ctx.loginManager || createAgentLoginManager();

  router.get('/api/agent-auth/login/start', (req, res) => {
    const agentKey = String(req.query.agent || '').trim();
    const agent = getAgent(agentKey);
    if (!agent) return res.status(400).json({ error: 'agent is required' });
    let session;
    try {
      session = loginManager.start(agent.key);
    } catch (err) {
      const status = err.code === 'CLI_NOT_INSTALLED' ? 404 : 400;
      return sendError(res, status, err);
    }

    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });
    let unsubscribe = () => {};
    let terminalEventReplayed = false;
    unsubscribe = loginManager.subscribe(session.id, (event) => {
      writeStreamEvent(res, event.type, event.data);
      if (event.type === 'login_done' || event.type === 'login_error') {
        clearAgentStatusCache();
        if (!res.writableEnded) res.end();
        terminalEventReplayed = true;
        unsubscribe();
      }
    });
    if (terminalEventReplayed) unsubscribe();
    req.on('close', () => unsubscribe());
    return undefined;
  });

  router.post('/api/agent-auth/login/code', (req, res) => {
    const body = req.body || {};
    try {
      loginManager.submitCode(body.sessionId, body.code);
      return res.json({ ok: true });
    } catch (err) {
      return sendError(res, err.code === 'LOGIN_SESSION_NOT_FOUND' ? 404 : 409, err);
    }
  });

  router.get('/api/agent-auth/login/status', (req, res) => {
    const sessionId = String(req.query.sessionId || '').trim();
    const session = sessionId ? loginManager.status(sessionId) : null;
    if (!session) {
      return res.status(404).json({
        error: 'login session not found',
        code: 'LOGIN_SESSION_NOT_FOUND',
      });
    }
    const agentStatus = getAgentStatuses()[session.agent] || null;
    return res.json({ ok: true, session, agentStatus });
  });

  return router;
};
