'use strict';

const fs = require('fs');
const path = require('path');

// Server-side chat history. The app keeps no local copy of the conversation;
// it pulls history back from here (the CLI host) when it reopens. Keyed by
// scopeKey (`workdir\0agentKey[\0sessionId]`), matching the session key used in
// agents.js, so history and the resumable CLI session are cleared together.
const HISTORY_FILE = path.join(__dirname, '..', 'chat-history.json');
const MAX_PER_SCOPE = 200; // Cap per conversation so the file can't grow forever.
const SCOPE_SEPARATOR = '\u0000';
const LEGACY_SESSION_ID = 'default';

function loadAll() {
  try {
    return JSON.parse(fs.readFileSync(HISTORY_FILE, 'utf-8'));
  } catch (_err) {
    return {};
  }
}

function saveAll(data) {
  fs.writeFileSync(HISTORY_FILE, JSON.stringify(data), { mode: 0o600 });
}

function readHistory(scopeKey) {
  const list = loadAll()[scopeKey];
  return Array.isArray(list) ? list : [];
}

function upsertHistoryMessage(scopeKey, message) {
  if (!message || !message.id) return;
  const all = loadAll();
  const list = Array.isArray(all[scopeKey]) ? all[scopeKey] : [];
  const index = list.findIndex((item) => item && item.id === message.id);
  if (index === -1) {
    list.push(message);
  } else {
    list[index] = {
      ...list[index],
      ...message,
      metadata: {
        ...(list[index].metadata || {}),
        ...(message.metadata || {}),
      },
    };
  }
  if (list.length > MAX_PER_SCOPE) {
    list.splice(0, list.length - MAX_PER_SCOPE);
  }
  all[scopeKey] = list;
  saveAll(all);
}

function updateHistoryMessage(scopeKey, messageId, updater) {
  if (!messageId || typeof updater !== 'function') return false;
  const all = loadAll();
  const list = Array.isArray(all[scopeKey]) ? all[scopeKey] : [];
  const index = list.findIndex((item) => item && item.id === messageId);
  if (index === -1) return false;
  const next = updater(list[index]);
  if (!next) return false;
  list[index] = next;
  all[scopeKey] = list;
  saveAll(all);
  return true;
}

// Rewrite any still-"streaming" messages in a list as cancelled (used when a
// turn's stream is gone but history was left mid-flight). Returns the new list
// and how many entries changed.
function finalizeStreamingList(list, now) {
  let changed = 0;
  const next = list.map((message) => {
    const metadata =
      message &&
      typeof message.metadata === 'object' &&
      !Array.isArray(message.metadata)
        ? message.metadata
        : {};
    if (!message || metadata.streaming !== true) return message;
    changed += 1;
    return {
      ...message,
      updatedAt: now,
      metadata: {
        ...metadata,
        streaming: false,
        awaitingFirstToken: false,
        cancelled: true,
      },
    };
  });
  return { list: next, changed };
}

function finalizeStaleStreamingHistory(scopeKey) {
  const all = loadAll();
  const list = Array.isArray(all[scopeKey]) ? all[scopeKey] : [];
  const { list: next, changed } = finalizeStreamingList(list, new Date().toISOString());
  if (changed > 0) {
    all[scopeKey] = next;
    saveAll(all);
  }
  return changed;
}

function finalizeAllStaleStreamingHistory() {
  const all = loadAll();
  let changed = 0;
  const now = new Date().toISOString();
  for (const [scopeKey, list] of Object.entries(all)) {
    if (!Array.isArray(list)) continue;
    const result = finalizeStreamingList(list, now);
    all[scopeKey] = result.list;
    changed += result.changed;
  }
  if (changed > 0) saveAll(all);
  return changed;
}

function clearHistory(scopeKey) {
  const all = loadAll();
  if (!(scopeKey in all)) return false;
  delete all[scopeKey];
  saveAll(all);
  return true;
}

function scopeInfo(scopeKey) {
  const parts = String(scopeKey || '').split(SCOPE_SEPARATOR);
  if (parts.length < 2) return null;
  return {
    workdir: parts[0],
    agentKey: parts[1],
    sessionId: parts[2] || LEGACY_SESSION_ID,
  };
}

function textForMessage(message) {
  return typeof (message && message.content) === 'string'
    ? message.content
    : '';
}

function redactSensitiveText(value) {
  return String(value || '')
    .replace(/\bBearer\s+[A-Za-z0-9._~+/-=]{20,}/gi, 'Bearer [redacted]')
    .replace(
      /\b(Authorization:\s*Bearer\s+)[A-Za-z0-9._~+/-=]{20,}/gi,
      '$1[redacted]',
    )
    .replace(
      /\b((?:accessToken|refreshToken|token|api[_-]?key|secret|password)\s*[:=]\s*["']?)[^"'\s,}]{8,}/gi,
      '$1[redacted]',
    )
    .replace(
      /\b[A-Za-z0-9_-]{32,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b/g,
      '[redacted-token]',
    );
}

function snippetFor(text, query) {
  const compact = redactSensitiveText(text).replace(/\s+/g, ' ').trim();
  if (!compact) return '';
  const lower = compact.toLowerCase();
  const needle = String(query || '').toLowerCase();
  const index = lower.indexOf(needle);
  const start = Math.max(0, index === -1 ? 0 : index - 80);
  const end = Math.min(compact.length, (index === -1 ? 0 : index) + needle.length + 120);
  const prefix = start > 0 ? '...' : '';
  const suffix = end < compact.length ? '...' : '';
  return `${prefix}${compact.slice(start, end)}${suffix}`;
}

function historyScopesFor({ workdir, agentKey }) {
  const all = loadAll();
  const scopes = [];
  for (const [scopeKey, messages] of Object.entries(all)) {
    const info = scopeInfo(scopeKey);
    if (!info || info.workdir !== workdir) continue;
    if (agentKey && info.agentKey !== agentKey) continue;
    scopes.push({
      ...info,
      scopeKey,
      messages: Array.isArray(messages) ? messages : [],
    });
  }
  return scopes;
}

function searchHistory({ workdir, query, agentKey = '', sessionNameFor, limit = 50 }) {
  const needle = String(query || '').trim().toLowerCase();
  if (!needle) return [];
  const matches = [];
  for (const scope of historyScopesFor({ workdir, agentKey })) {
    for (const message of scope.messages) {
      const content = textForMessage(message);
      if (!content.toLowerCase().includes(needle)) continue;
      matches.push({
        agentKey: scope.agentKey,
        sessionId: scope.sessionId,
        sessionName:
          typeof sessionNameFor === 'function'
            ? sessionNameFor(scope.agentKey, scope.sessionId)
            : scope.sessionId,
        snippet: snippetFor(content, needle),
        messageId: String((message && message.id) || ''),
      });
      if (matches.length >= limit) return matches;
    }
  }
  return matches;
}

function markdownForConversation({ agentLabel, sessionName, messages, exportedAt }) {
  const lines = [
    '# Relay Conversation Export',
    '',
    `- Agent: ${agentLabel || 'Unknown'}`,
    `- Session: ${sessionName || 'Main'}`,
    `- Exported: ${exportedAt}`,
    '',
  ];
  for (const message of Array.isArray(messages) ? messages : []) {
    const role = String((message && message.role) || 'message');
    const createdAt = String((message && message.createdAt) || '');
    const title = `${role.slice(0, 1).toUpperCase()}${role.slice(1)}`;
    lines.push(`## ${title}${createdAt ? ` - ${createdAt}` : ''}`);
    lines.push('');
    const content = redactSensitiveText(textForMessage(message)).trim();
    lines.push(content || '_No content_');
    lines.push('');
  }
  return `${lines.join('\n').trim()}\n`;
}

module.exports = {
  readHistory,
  upsertHistoryMessage,
  updateHistoryMessage,
  finalizeStaleStreamingHistory,
  finalizeAllStaleStreamingHistory,
  clearHistory,
  historyScopesFor,
  searchHistory,
  markdownForConversation,
};
