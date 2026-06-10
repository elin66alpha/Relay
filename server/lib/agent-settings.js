'use strict';

// Per-scope Model / Effort / Permission selections, persisted to disk so every
// device sharing a `workdir + agent` scope sees the same choice (matching the
// shared-session design). The store maps a scope key string -> { model, effort,
// permission }. Selections are normalized against agent-options on read and
// write, so an unknown id silently falls back to the agent's default and a
// never-configured scope starts from that agent's default selection.

const path = require('path');

const { defaultsFor, normalizeSettings } = require('./agent-options');
const { createJsonStore } = require('./json-store');

const SETTINGS_FILE = path.join(__dirname, '..', 'agent-settings.json');

// Cached, atomic store: getSettings runs on every agent turn, so reads must not
// hit the disk each time.
const store = createJsonStore(SETTINGS_FILE, { defaultValue: {} });

// Effective settings for a scope: stored selection normalized for the agent,
// falling back to defaults for any group not yet chosen or not supported.
function getSettings(agentKey, scopeKey) {
  const stored = store.load()[scopeKey] || {};
  return normalizeSettings(agentKey, { ...defaultsFor(agentKey), ...stored });
}

// Persist a (partial) selection for a scope. Only the provided groups change;
// the merged result is normalized so invalid ids never reach disk. Returns the
// new effective settings.
function setSettings(agentKey, scopeKey, partial) {
  return store.mutate((all) => {
    const merged = normalizeSettings(agentKey, {
      ...defaultsFor(agentKey),
      ...(all[scopeKey] || {}),
      ...(partial || {}),
    });
    all[scopeKey] = merged;
    return merged;
  });
}

module.exports = { getSettings, setSettings };
