'use strict';

const fs = require('fs');
const path = require('path');

// Server-side chat history. The app keeps no local copy of the conversation;
// it pulls history back from here (the CLI host) when it reopens. Keyed by
// scopeKey (`workdir\0agentKey[\0sessionId]`), matching the session key used in
// agents.js, so history and the resumable CLI session are cleared together.
const HISTORY_FILE = process.env.RELAY_HISTORY_FILE
  ? path.resolve(process.env.RELAY_HISTORY_FILE)
  : path.join(__dirname, '..', 'chat-history.json');
const MAX_PER_SCOPE = 200; // Cap per conversation so the file can't grow forever.
const SCOPE_SEPARATOR = '\u0000';
const MAIN_SESSION_ID = 'default';
const FLUSH_IDLE_MS = 300;
const FLUSH_MAX_MS = 2000;

let cache = null;
let cacheLoaded = false;
let dirty = false;
let flushTimer = null;
let maxFlushTimer = null;

// A missing file is a fresh start. A file that exists but cannot be loaded is
// set aside instead of read as empty, because the next flush would overwrite it.
// shortcut: if the rename fails too, the next flush still overwrites the file.
function loadAll() {
  try {
    return JSON.parse(fs.readFileSync(HISTORY_FILE, 'utf-8'));
  } catch (err) {
    if (err.code === 'ENOENT') return {};
    const aside = `${HISTORY_FILE}.corrupt-${Date.now()}`;
    try {
      fs.renameSync(HISTORY_FILE, aside);
      console.warn(`[history] could not load chat history (${err.message}); kept it as ${aside}`);
    } catch (renameErr) {
      console.warn(`[history] could not load chat history (${err.message}) or set it aside: ${renameErr.message}`);
    }
    return {};
  }
}

function saveAll(data) {
  const tmp = `${HISTORY_FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data), { mode: 0o600 });
  fs.renameSync(tmp, HISTORY_FILE);
}

// Background flush path. The debounced timer fires constantly while an agent
// turn streams deltas, so neither its disk I/O nor its JSON.stringify may block
// the event loop the way a whole-history writeFileSync would. The file is
// written scope by scope in chunks, which hands the event loop back between
// chunks; the bytes equal JSON.stringify(data). A scope that changes mid-write
// marks the history dirty again, so the next flush saves it. Writes are chained
// so two timer flushes can never interleave on the temp file; the synchronous
// saveAll stays for shutdown (process.on('exit') cannot await) and uses its own
// temp name so it can't collide with an in-flight async write.
const WRITE_CHUNK_CHARS = 64 * 1024;
let writeChain = Promise.resolve();

async function writeHistoryFile(data) {
  const tmp = `${HISTORY_FILE}.tmp-async`;
  const handle = await fs.promises.open(tmp, 'w', 0o600);
  try {
    let chunk = '{';
    let first = true;
    for (const [scopeKey, list] of Object.entries(data)) {
      chunk += `${first ? '' : ','}${JSON.stringify(scopeKey)}:${JSON.stringify(list)}`;
      first = false;
      if (chunk.length >= WRITE_CHUNK_CHARS) {
        await handle.write(chunk);
        chunk = '';
      }
    }
    await handle.write(`${chunk}}`);
  } finally {
    await handle.close();
  }
  await fs.promises.rename(tmp, HISTORY_FILE);
}

function saveAllAsync(data) {
  writeChain = writeChain.then(() => writeHistoryFile(data));
  return writeChain;
}

function ensureLoaded() {
  if (!cacheLoaded) {
    cache = loadAll();
    cacheLoaded = true;
  }
  return cache;
}

function unrefTimer(timer) {
  if (timer && typeof timer.unref === 'function') timer.unref();
}

function clearFlushTimers() {
  if (flushTimer) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
  if (maxFlushTimer) {
    clearTimeout(maxFlushTimer);
    maxFlushTimer = null;
  }
}

function flushHistory() {
  clearFlushTimers();
  if (!dirty) return false;
  saveAll(ensureLoaded());
  dirty = false;
  return true;
}

function flushFromTimer() {
  clearFlushTimers();
  if (!dirty) return;
  dirty = false;
  saveAllAsync(ensureLoaded()).catch((err) => {
    dirty = true;
    console.warn(`[history] failed to flush chat history: ${err.message}`);
  });
}

function scheduleFlush() {
  dirty = true;
  if (flushTimer) clearTimeout(flushTimer);
  flushTimer = setTimeout(flushFromTimer, FLUSH_IDLE_MS);
  unrefTimer(flushTimer);
  if (!maxFlushTimer) {
    maxFlushTimer = setTimeout(flushFromTimer, FLUSH_MAX_MS);
    unrefTimer(maxFlushTimer);
  }
}

function readHistory(scopeKey) {
  const list = ensureLoaded()[scopeKey];
  return Array.isArray(list) ? list : [];
}

function upsertHistoryMessage(scopeKey, message) {
  if (!message || !message.id) return;
  const all = ensureLoaded();
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
  scheduleFlush();
}

function updateHistoryMessage(scopeKey, messageId, updater) {
  if (!messageId || typeof updater !== 'function') return false;
  const all = ensureLoaded();
  const list = Array.isArray(all[scopeKey]) ? all[scopeKey] : [];
  const index = list.findIndex((item) => item && item.id === messageId);
  if (index === -1) return false;
  const next = updater(list[index]);
  if (!next) return false;
  list[index] = next;
  all[scopeKey] = list;
  scheduleFlush();
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
  const all = ensureLoaded();
  const list = Array.isArray(all[scopeKey]) ? all[scopeKey] : [];
  const { list: next, changed } = finalizeStreamingList(list, new Date().toISOString());
  if (changed > 0) {
    all[scopeKey] = next;
    scheduleFlush();
  }
  return changed;
}

function finalizeAllStaleStreamingHistory() {
  const all = ensureLoaded();
  let changed = 0;
  const now = new Date().toISOString();
  for (const [scopeKey, list] of Object.entries(all)) {
    if (!Array.isArray(list)) continue;
    const result = finalizeStreamingList(list, now);
    all[scopeKey] = result.list;
    changed += result.changed;
  }
  if (changed > 0) scheduleFlush();
  return changed;
}

function clearHistory(scopeKey) {
  const all = ensureLoaded();
  if (!(scopeKey in all)) return false;
  delete all[scopeKey];
  scheduleFlush();
  return true;
}

function scopeInfo(scopeKey) {
  const parts = String(scopeKey || '').split(SCOPE_SEPARATOR);
  if (parts.length < 2) return null;
  return {
    workdir: parts[0],
    agentKey: parts[1],
    sessionId: parts[2] || MAIN_SESSION_ID,
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
  const all = ensureLoaded();
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

// Work directories with conversation history, most recently active first.
function recentWorkdirs(limit = 10) {
  const latest = new Map();
  for (const [scopeKey, messages] of Object.entries(ensureLoaded())) {
    const info = scopeInfo(scopeKey);
    if (!info || !Array.isArray(messages) || messages.length === 0) continue;
    const last = messages[messages.length - 1] || {};
    const at = String(last.createdAt || last.updatedAt || '');
    if (!latest.has(info.workdir) || at > latest.get(info.workdir)) {
      latest.set(info.workdir, at);
    }
  }
  return [...latest]
    .sort((a, b) => b[1].localeCompare(a[1]))
    .slice(0, limit)
    .map(([workdir]) => workdir);
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
  flushHistory,
  clearHistory,
  redactSensitiveText,
  recentWorkdirs,
  searchHistory,
  markdownForConversation,
};
