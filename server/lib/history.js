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

function clearHistory(scopeKey) {
  const all = loadAll();
  if (!(scopeKey in all)) return false;
  delete all[scopeKey];
  saveAll(all);
  return true;
}

module.exports = { readHistory, appendHistory, clearHistory };
