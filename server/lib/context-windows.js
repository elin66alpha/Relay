'use strict';

const path = require('path');
const { createJsonStore } = require('./json-store');

const CONTEXT_WINDOWS_FILE = process.env.RELAY_CONTEXT_WINDOWS_FILE
  ? path.resolve(process.env.RELAY_CONTEXT_WINDOWS_FILE)
  : path.join(__dirname, '..', 'context-windows.json');
const store = createJsonStore(CONTEXT_WINDOWS_FILE, { defaultValue: {} });

function windowKey(agentKey, model) {
  return JSON.stringify([agentKey, model || 'default']);
}

function recordContextWindow(agentKey, model, size) {
  if (!Number.isInteger(size) || size <= 0) return;
  const all = store.load();
  const key = windowKey(agentKey, model);
  if (all[key] === size) return;
  all[key] = size;
  store.save(all);
}

function contextWindowFor(agentKey, model) {
  const size = store.load()[windowKey(agentKey, model)];
  return Number.isInteger(size) && size > 0 ? size : null;
}

module.exports = { recordContextWindow, contextWindowFor };
