'use strict';

// Per-session Model / Effort / Permission / Fast selections, persisted to disk
// so every device viewing the same session sees the same choice. The store maps
// a session scope key to its supported selections. Main's scope key is the
// `workdir + agent` context key, so a session with no entry of its own falls
// back to Main's; a new session gets a copy of the settings it was created from
// and is independent after that. Values are normalized on read and write, so an
// unknown id silently falls back to the agent's default.

const path = require('path');

const { normalizeSettings } = require('./agent-options');
const { createJsonStore } = require('./json-store');

const SETTINGS_FILE = process.env.RELAY_AGENT_SETTINGS_FILE
  ? path.resolve(process.env.RELAY_AGENT_SETTINGS_FILE)
  : path.join(__dirname, '..', 'agent-settings.json');

// Cached, atomic store: getSettings runs on every agent turn, so reads must not
// hit the disk each time.
const store = createJsonStore(SETTINGS_FILE, { defaultValue: {} });

function storedFor(all, scopeKey, fallbackKey) {
  return all[scopeKey] || (fallbackKey && all[fallbackKey]) || {};
}

// Effective settings for a session: its own selection, else the fallback
// (Main's), normalized for the agent. normalizeSettings already falls back to
// the agent's default for any group that is unset or unsupported.
function getSettings(agentKey, scopeKey, fallbackKey) {
  return normalizeSettings(agentKey, storedFor(store.load(), scopeKey, fallbackKey));
}

// Persist a (partial) selection for a session. Only the provided groups change,
// on top of what the session currently resolves to; the merged result is
// normalized so invalid ids never reach disk. Returns the new effective settings.
function setSettings(agentKey, scopeKey, partial, fallbackKey) {
  return store.mutate((all) => {
    const merged = normalizeSettings(agentKey, {
      ...storedFor(all, scopeKey, fallbackKey),
      ...(partial || {}),
    });
    all[scopeKey] = merged;
    return merged;
  });
}

function deleteSettings(scopeKey) {
  store.mutate((all) => {
    delete all[scopeKey];
  });
}

module.exports = { getSettings, setSettings, deleteSettings };
