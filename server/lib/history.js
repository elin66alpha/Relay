'use strict';

const fs = require('fs');
const path = require('path');

// Server-side chat history. The app keeps no local copy of the conversation;
// it pulls history back from here (the CLI host) when it reopens. Keyed by
// scopeKey (`deviceId:agentKey`), matching the session key used in agents.js,
// so history and the resumable CLI session are cleared together.
const HISTORY_FILE = path.join(__dirname, '..', 'chat-history.json');
const MAX_PER_SCOPE = 200; // Cap per conversation so the file can't grow forever.

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

function appendHistory(scopeKey, messages) {
  if (!Array.isArray(messages) || messages.length === 0) return;
  const all = loadAll();
  const list = Array.isArray(all[scopeKey]) ? all[scopeKey] : [];
  list.push(...messages);
  if (list.length > MAX_PER_SCOPE) {
    list.splice(0, list.length - MAX_PER_SCOPE);
  }
  all[scopeKey] = list;
  saveAll(all);
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

function finalizeStaleStreamingHistory(scopeKey) {
  const all = loadAll();
  const list = Array.isArray(all[scopeKey]) ? all[scopeKey] : [];
  let changed = 0;
  const now = new Date().toISOString();
  all[scopeKey] = list.map((message) => {
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
  if (changed > 0) saveAll(all);
  return changed;
}

function finalizeAllStaleStreamingHistory() {
  const all = loadAll();
  let changed = 0;
  const now = new Date().toISOString();
  for (const [scopeKey, list] of Object.entries(all)) {
    if (!Array.isArray(list)) continue;
    all[scopeKey] = list.map((message) => {
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

module.exports = {
  readHistory,
  appendHistory,
  upsertHistoryMessage,
  updateHistoryMessage,
  finalizeStaleStreamingHistory,
  finalizeAllStaleStreamingHistory,
  clearHistory,
};
