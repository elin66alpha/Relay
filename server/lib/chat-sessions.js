'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const SESSIONS_FILE = path.join(__dirname, '..', 'chat-sessions.json');
const LEGACY_SESSION_ID = 'default';
// Upper bound on named chat sessions per workdir+agent (includes the default
// "Main" session). Keeps chat-sessions.json bounded and the drawer manageable.
const MAX_SESSIONS = 8;

function loadAll() {
  try {
    return JSON.parse(fs.readFileSync(SESSIONS_FILE, 'utf-8'));
  } catch (_err) {
    return {};
  }
}

function saveAll(data) {
  fs.writeFileSync(SESSIONS_FILE, JSON.stringify(data), { mode: 0o600 });
}

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
    id: LEGACY_SESSION_ID,
    name: 'Main',
    createdAt: now,
    updatedAt: now,
  };
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
    sessions.push({
      id,
      name: normalizeName(item.name, id === LEGACY_SESSION_ID ? 'Main' : 'Session'),
      createdAt: String(item.createdAt || now),
      updatedAt: String(item.updatedAt || item.createdAt || now),
    });
  }
  if (sessions.length === 0) {
    sessions.push(defaultSession(now));
  }
  const active = validSessionId(raw && raw.activeSessionId);
  const activeSessionId = sessions.some((session) => session.id === active)
    ? active
    : sessions[0].id;
  sessions.sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
  return { activeSessionId, sessions };
}

function sessionScopeKey(contextKey, sessionId) {
  const id = validSessionId(sessionId) || LEGACY_SESSION_ID;
  return id === LEGACY_SESSION_ID ? contextKey : `${contextKey}\u0000${id}`;
}

function contextPayload(context) {
  return {
    activeSessionId: context.activeSessionId,
    sessions: context.sessions.map((session) => ({ ...session })),
  };
}

function listChatSessions(contextKey) {
  const all = loadAll();
  const existed = Object.prototype.hasOwnProperty.call(all, contextKey);
  const context = normalizeContext(all[contextKey]);
  all[contextKey] = context;
  if (!existed) saveAll(all);
  return contextPayload(context);
}

function resolveChatSession(contextKey, requestedSessionId) {
  const all = loadAll();
  const context = normalizeContext(all[contextKey]);
  all[contextKey] = context;
  const requested = validSessionId(requestedSessionId);
  let session = null;
  if (String(requestedSessionId || '').trim()) {
    session = requested
      ? context.sessions.find((item) => item.id === requested)
      : null;
  } else {
    session =
      context.sessions.find((item) => item.id === context.activeSessionId) ||
      context.sessions[0];
  }
  saveAll(all);
  return session ? { ...session } : null;
}

function createChatSession(contextKey, rawName) {
  const all = loadAll();
  const context = normalizeContext(all[contextKey]);
  if (context.sessions.length >= MAX_SESSIONS) {
    return null;
  }
  const now = new Date().toISOString();
  const session = {
    id: crypto.randomUUID(),
    name: normalizeName(rawName, nextSessionName(context.sessions)),
    createdAt: now,
    updatedAt: now,
  };
  context.sessions.unshift(session);
  context.activeSessionId = session.id;
  all[contextKey] = context;
  saveAll(all);
  return contextPayload(context);
}

function setActiveChatSession(contextKey, sessionId) {
  const id = validSessionId(sessionId);
  if (!id) return null;
  const all = loadAll();
  const context = normalizeContext(all[contextKey]);
  const session = context.sessions.find((item) => item.id === id);
  if (!session) return null;
  context.activeSessionId = id;
  all[contextKey] = context;
  saveAll(all);
  return contextPayload(context);
}

function touchChatSession(contextKey, sessionId) {
  const id = validSessionId(sessionId);
  if (!id) return null;
  const all = loadAll();
  const context = normalizeContext(all[contextKey]);
  const session = context.sessions.find((item) => item.id === id);
  if (!session) return null;
  session.updatedAt = new Date().toISOString();
  context.activeSessionId = id;
  all[contextKey] = context;
  saveAll(all);
  return { ...session };
}

function deleteChatSession(contextKey, sessionId) {
  const id = validSessionId(sessionId);
  if (!id) return null;
  const all = loadAll();
  const context = normalizeContext(all[contextKey]);
  const index = context.sessions.findIndex((session) => session.id === id);
  if (index === -1) return null;
  const [deleted] = context.sessions.splice(index, 1);
  if (context.sessions.length === 0) {
    context.sessions.push(defaultSession(new Date().toISOString()));
  }
  if (context.activeSessionId === id) {
    context.activeSessionId = context.sessions[0].id;
  }
  all[contextKey] = context;
  saveAll(all);
  return {
    deleted,
    ...contextPayload(context),
  };
}

module.exports = {
  LEGACY_SESSION_ID,
  MAX_SESSIONS,
  listChatSessions,
  resolveChatSession,
  createChatSession,
  setActiveChatSession,
  touchChatSession,
  deleteChatSession,
  sessionScopeKey,
};
