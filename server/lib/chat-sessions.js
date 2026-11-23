'use strict';

const crypto = require('crypto');
const path = require('path');

const { createJsonStore } = require('./json-store');

const SESSIONS_FILE = process.env.RELAY_CHAT_SESSIONS_FILE
  ? path.resolve(process.env.RELAY_CHAT_SESSIONS_FILE)
  : path.join(__dirname, '..', 'chat-sessions.json');
const MAIN_SESSION_ID = 'default';
// Upper bound on named chat sessions per workdir+agent (includes the default
// "Main" session). Keeps chat-sessions.json bounded and the drawer manageable.
const MAX_SESSIONS = 8;
// Separate cap for hidden swarm-member sessions hosted on this machine for a
// remote coordinator, so swarms never crowd out the user's own chat sessions.
const MAX_SWARM_SESSIONS = 32;
const SWARM_SESSION_KIND = 'swarm';

// Cached, atomic store. Read paths (list/resolve) normalize in memory and never
// write; only explicit mutations (create/activate/touch/rename/delete) persist. This
// keeps GET /api/history and friends from rewriting the file on every request.
const store = createJsonStore(SESSIONS_FILE, { defaultValue: {} });

function validSessionId(value) {
  const text = String(value || '').trim();
  return /^[A-Za-z0-9._-]{1,96}$/.test(text) ? text : '';
}

function normalizeName(value, fallback) {
  const text = String(value || '')
    .replace(/\s+/g, ' ')
    .trim();
  return (text || fallback).slice(0, 80);
}

function nextSessionName(sessions) {
  const names = new Set(sessions.map((session) => session.name));
  for (let i = 1; i < 1000; i += 1) {
    const candidate = `Session ${i}`;
    if (!names.has(candidate)) return candidate;
  }
  return `Session ${sessions.length + 1}`;
}

function defaultSession(now) {
  return {
    id: MAIN_SESSION_ID,
    name: 'Main',
    createdAt: now,
    updatedAt: now,
  };
}

function isSwarmSession(session) {
  return Boolean(session && session.kind === SWARM_SESSION_KIND);
}

function normalizeContext(raw, now = new Date().toISOString()) {
  const list = Array.isArray(raw && raw.sessions) ? raw.sessions : [];
  const sessions = [];
  const seen = new Set();
  for (const item of list) {
    if (!item || typeof item !== 'object') continue;
    const id = validSessionId(item.id);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    const entry = {
      id,
      name: normalizeName(item.name, id === MAIN_SESSION_ID ? 'Main' : 'Session'),
      createdAt: String(item.createdAt || now),
      updatedAt: String(item.updatedAt || item.createdAt || now),
    };
    if (item.kind === SWARM_SESSION_KIND) entry.kind = SWARM_SESSION_KIND;
    sessions.push(entry);
  }
  if (!sessions.some((session) => !isSwarmSession(session))) {
    sessions.push(defaultSession(now));
  }
  const regular = sessions.filter((session) => !isSwarmSession(session));
  const active = validSessionId(raw && raw.activeSessionId);
  const activeSessionId = regular.some((session) => session.id === active)
    ? active
    : regular[0].id;
  sessions.sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
  return { activeSessionId, sessions };
}

// Session context = work directory + agent. Individual chat sessions hang under
// that context and each keeps its own history plus resumable CLI session. NUL
// separates parts so no real path can collide with the agent/session suffix.
const SCOPE_SEPARATOR = '\u0000';

function sessionScopeKey(contextKey, sessionId) {
  const id = validSessionId(sessionId) || MAIN_SESSION_ID;
  return id === MAIN_SESSION_ID ? contextKey : `${contextKey}${SCOPE_SEPARATOR}${id}`;
}

function sessionContextKeyFor(agentKey, workdir) {
  return `${workdir}${SCOPE_SEPARATOR}${agentKey}`;
}

function scopeKeyFor(agentKey, workdir, sessionId) {
  return sessionScopeKey(sessionContextKeyFor(agentKey, workdir), sessionId);
}

function contextPayload(context) {
  return {
    activeSessionId: context.activeSessionId,
    sessions: context.sessions
      .filter((session) => !isSwarmSession(session))
      .map((session) => ({ ...session })),
  };
}

function contextFor(contextKey) {
  return normalizeContext(store.load()[contextKey]);
}

function saveContext(contextKey, context) {
  store.mutate((all) => {
    all[contextKey] = context;
  });
}

function listChatSessions(contextKey) {
  return contextPayload(contextFor(contextKey));
}

function resolveChatSession(contextKey, requestedSessionId) {
  const context = contextFor(contextKey);
  const requested = validSessionId(requestedSessionId);
  let session;
  if (String(requestedSessionId || '').trim()) {
    session = requested
      ? context.sessions.find((item) => item.id === requested)
      : null;
  } else {
    session =
      context.sessions.find((item) => item.id === context.activeSessionId) ||
      context.sessions[0];
  }
  return session ? { ...session } : null;
}

function createChatSession(contextKey, rawName, options = {}) {
  const context = contextFor(contextKey);
  const swarm = options && options.kind === SWARM_SESSION_KIND;
  const regular = context.sessions.filter((session) => !isSwarmSession(session));
  if (swarm) {
    const swarmCount = context.sessions.length - regular.length;
    if (swarmCount >= MAX_SWARM_SESSIONS) return null;
  } else if (regular.length >= MAX_SESSIONS) {
    return null;
  }
  const now = new Date().toISOString();
  const session = {
    id: crypto.randomUUID(),
    name: normalizeName(rawName, nextSessionName(regular)),
    ...(swarm ? { kind: SWARM_SESSION_KIND } : {}),
    createdAt: now,
    updatedAt: now,
  };
  context.sessions.unshift(session);
  if (!swarm) {
    context.activeSessionId = session.id;
  }
  saveContext(contextKey, context);
  const payload = contextPayload(context);
  return swarm ? { ...payload, session: { ...session } } : payload;
}

function setActiveChatSession(contextKey, sessionId) {
  const id = validSessionId(sessionId);
  if (!id) return null;
  const context = contextFor(contextKey);
  const session = context.sessions.find((item) => item.id === id);
  if (!session || isSwarmSession(session)) return null;
  context.activeSessionId = id;
  saveContext(contextKey, context);
  return contextPayload(context);
}

function touchChatSession(contextKey, sessionId) {
  const id = validSessionId(sessionId);
  if (!id) return null;
  const context = contextFor(contextKey);
  const session = context.sessions.find((item) => item.id === id);
  if (!session) return null;
  session.updatedAt = new Date().toISOString();
  if (!isSwarmSession(session)) {
    context.activeSessionId = id;
  }
  saveContext(contextKey, context);
  return { ...session };
}

function deleteChatSession(contextKey, sessionId) {
  const id = validSessionId(sessionId);
  if (!id) return null;
  const context = contextFor(contextKey);
  const index = context.sessions.findIndex((session) => session.id === id);
  if (index === -1) return null;
  const [deleted] = context.sessions.splice(index, 1);
  if (!context.sessions.some((session) => !isSwarmSession(session))) {
    context.sessions.push(defaultSession(new Date().toISOString()));
  }
  if (context.activeSessionId === id) {
    const firstRegular = context.sessions.find((session) => !isSwarmSession(session));
    context.activeSessionId = firstRegular.id;
  }
  saveContext(contextKey, context);
  return {
    deleted,
    ...contextPayload(context),
  };
}

function renameChatSession(contextKey, sessionId, rawName) {
  const context = contextFor(contextKey);
  const session = context.sessions.find((item) => item.id === sessionId);
  if (!session) return null;
  session.name = normalizeName(rawName, '');
  saveContext(contextKey, context);
  return contextPayload(context);
}

module.exports = {
  MAIN_SESSION_ID,
  MAX_SESSIONS,
  MAX_SWARM_SESSIONS,
  SCOPE_SEPARATOR,
  isSwarmSession,
  listChatSessions,
  resolveChatSession,
  createChatSession,
  setActiveChatSession,
  touchChatSession,
  deleteChatSession,
  renameChatSession,
  sessionScopeKey,
  sessionContextKeyFor,
  scopeKeyFor,
};
