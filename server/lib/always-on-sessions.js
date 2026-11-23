'use strict';

// In-memory registry of solo-chat sessions pinned as always-on. Keyed by the
// conversation scope key (`scopeKeyFor(agentKey, workdir, sessionId)`), which
// matches the `key` every session pool entry uses.
//
// State lives only in backend memory: a backend restart clears every mark.
// `list()` returns entries in insertion order (oldest pinned first).
const MAX_ALWAYS_ON = 3;

function createAlwaysOnSessions({
  max = MAX_ALWAYS_ON,
  now = () => new Date().toISOString(),
} = {}) {
  const entries = new Map();

  function has(key) {
    return entries.has(key);
  }

  function add(key, info = {}) {
    if (entries.has(key)) return true;
    if (entries.size >= max) return false;
    entries.set(key, {
      key,
      agentKey: info.agentKey,
      workdir: info.workdir,
      sessionId: info.sessionId,
      since: info.since || now(),
    });
    return true;
  }

  function remove(key) {
    return entries.delete(key);
  }

  function list() {
    return [...entries.values()].map((entry) => ({ ...entry }));
  }

  return {
    MAX_ALWAYS_ON: max,
    has,
    add,
    remove,
    list,
  };
}

const alwaysOnSessions = createAlwaysOnSessions();

module.exports = {
  MAX_ALWAYS_ON,
  createAlwaysOnSessions,
  alwaysOnSessions,
};
