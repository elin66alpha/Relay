'use strict';

const express = require('express');

module.exports = function createSessionsRouter(ctx) {
  const {
    MAIN_SESSION_ID,
    MAX_SESSIONS,
    MAX_SWARM_SESSIONS = 32,
    agentPayload,
    agentRequiredOrUnknownError,
    alwaysOnSessions,
    clearHistory,
    purgeSession,
    createChatSession,
    deleteChatSession,
    deleteSettings,
    getSettings,
    isSwarmSession,
    listChatSessions,
    renameChatSession,
    resolveAgentScope,
    resolveChatSession,
    runningScopes,
    scopeChains,
    scopeKeyFor,
    sessionContextKeyFor,
    setActiveChatSession,
    setSettings,
  } = ctx;
  const router = express.Router();

  function pruneStaleAlwaysOn() {
    const valid = [];
    for (const entry of alwaysOnSessions.list()) {
      const contextKey = sessionContextKeyFor(entry.agentKey, entry.workdir);
      const session = resolveChatSession(contextKey, entry.sessionId);
      if (!session || isSwarmSession(session)) {
        alwaysOnSessions.remove(entry.key);
        continue;
      }
      valid.push({
        agent: entry.agentKey,
        workdir: entry.workdir,
        sessionId: entry.sessionId,
        name: session.name,
      });
    }
    return valid;
  }

  // Matches stored entries only, so a malformed id never maps to another session.
  function removeAlwaysOn(agentKey, workdir, sessionId) {
    for (const entry of alwaysOnSessions.list()) {
      if (entry.agentKey === agentKey && entry.workdir === workdir && entry.sessionId === sessionId) {
        alwaysOnSessions.remove(entry.key);
      }
    }
  }

  function alwaysOnPayload() {
    return {
      ok: true,
      max: alwaysOnSessions.MAX_ALWAYS_ON,
      sessions: pruneStaleAlwaysOn(),
    };
  }

  router.get('/api/sessions', (req, res) => {
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
      features: ['swarm-sessions'],
      ...listChatSessions(contextKey),
    });
  });

  router.post('/api/sessions', (req, res) => {
    const agentKey = String(req.body.agent || '').trim();
    const scope = resolveAgentScope(req, res, {
      agentKey,
      requireSession: false,
      agentError: agentRequiredOrUnknownError,
    });
    if (!scope) return;
    const { agent, workdir, contextKey } = scope;
    const kind = req.body.kind === 'swarm' ? 'swarm' : undefined;
    const created = createChatSession(contextKey, req.body.name, kind ? { kind } : undefined);
    if (!created) {
      const cap = kind === 'swarm' ? MAX_SWARM_SESSIONS : MAX_SESSIONS;
      return res.status(409).json({
        error: `session limit reached (max ${cap})`,
        code: 'SESSION_LIMIT_REACHED',
      });
    }
    const newSessionId = created.session ? created.session.id : created.activeSessionId;
    // A new session starts from a copy of the settings of the session it was
    // created from (Main when none is named) and is independent after that.
    setSettings(
      agent.key,
      scopeKeyFor(agent.key, workdir, newSessionId),
      getSettings(
        agent.key,
        scopeKeyFor(agent.key, workdir, req.body.copySettingsFrom),
        contextKey,
      ),
    );
    return res.json({
      ok: true,
      agent: agentPayload(agent),
      workdir,
      ...(created.session ? { sessionId: created.session.id } : {}),
      ...created,
    });
  });

  router.post('/api/sessions/active', (req, res) => {
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

  router.post('/api/sessions/rename', (req, res) => {
    const agentKey = String(req.body.agent || '').trim();
    const sessionId = String(req.body.sessionId || '').trim();
    const name = String(req.body.name || '').trim();
    const scope = resolveAgentScope(req, res, {
      agentKey,
      requireSession: false,
      agentError: agentRequiredOrUnknownError,
      beforeWorkdir: () => {
        if (!sessionId) {
          res.status(400).json({ error: 'sessionId is required' });
          return false;
        }
        if (sessionId === MAIN_SESSION_ID) {
          res.status(400).json({
            error: 'the default session cannot be renamed',
            code: 'SESSION_PROTECTED',
          });
          return false;
        }
        if (!name) {
          res.status(400).json({
            error: 'session name is required',
            code: 'SESSION_NAME_REQUIRED',
          });
          return false;
        }
        return true;
      },
    });
    if (!scope) return;
    const { agent, workdir, contextKey } = scope;
    const result = renameChatSession(contextKey, sessionId, name);
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

  router.post('/api/sessions/delete', async (req, res) => {
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
        if (sessionId === MAIN_SESSION_ID) {
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
    const existing = resolveChatSession(contextKey, sessionId);
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
    alwaysOnSessions.remove(scopeKey);
    await purgeSession(scopeKey, { agentKey: agent.key, workdir });
    clearHistory(scopeKey);
    deleteSettings(scopeKey);
    return res.json({
      ok: true,
      agent: agentPayload(agent),
      workdir,
      deletedSessionId: sessionId,
      ...result,
    });
  });

  router.get('/api/sessions/always-on', (_req, res) => {
    return res.json(alwaysOnPayload());
  });

  router.post('/api/sessions/always-on', (req, res) => {
    const agentKey = String(req.body.agent || '').trim();
    const sessionId = String(req.body.sessionId || '').trim();
    const alwaysOn = req.body.alwaysOn;
    const scope = resolveAgentScope(req, res, {
      agentKey,
      requireSession: false,
      agentError: agentRequiredOrUnknownError,
      beforeWorkdir: () => {
        if (!sessionId) {
          res.status(400).json({ error: 'sessionId is required' });
          return false;
        }
        if (typeof alwaysOn !== 'boolean') {
          res.status(400).json({ error: 'alwaysOn must be a boolean' });
          return false;
        }
        return true;
      },
    });
    if (!scope) return;
    const { agent, workdir, contextKey } = scope;
    const existing = resolveChatSession(contextKey, sessionId);
    if (existing && isSwarmSession(existing)) {
      return res.status(400).json({
        error: 'swarm sessions cannot be always-on',
        code: 'SWARM_SESSION_NOT_SUPPORTED',
      });
    }
    if (alwaysOn) {
      if (!existing) {
        return res.status(404).json({ error: 'session not found', code: 'SESSION_NOT_FOUND' });
      }
      pruneStaleAlwaysOn();
      const scopeKey = scopeKeyFor(agent.key, workdir, existing.id);
      const added = alwaysOnSessions.add(scopeKey, {
        agentKey: agent.key,
        workdir,
        sessionId: existing.id,
      });
      if (!added) {
        return res.status(409).json({
          error: `always-on limit reached (max ${alwaysOnSessions.MAX_ALWAYS_ON})`,
          code: 'ALWAYS_ON_LIMIT',
        });
      }
    } else if (existing) {
      alwaysOnSessions.remove(scopeKeyFor(agent.key, workdir, existing.id));
    } else {
      removeAlwaysOn(agent.key, workdir, sessionId);
    }
    return res.json(alwaysOnPayload());
  });

  router.post('/api/sessions/always-on/remove', (req, res) => {
    const agentKey = String(req.body.agent || '').trim();
    const workdir = String(req.body.workdir || '').trim();
    const sessionId = String(req.body.sessionId || '').trim();
    if (!agentKey) {
      return res.status(400).json({ error: 'agent is required' });
    }
    if (!workdir) {
      return res.status(400).json({ error: 'workdir is required' });
    }
    if (!sessionId) {
      return res.status(400).json({ error: 'sessionId is required' });
    }
    removeAlwaysOn(agentKey, workdir, sessionId);
    return res.json(alwaysOnPayload());
  });

  return router;
};
