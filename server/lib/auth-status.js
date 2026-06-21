'use strict';

const { getAgentStatuses } = require('./agent-status');

// Backward-compatible helper for older UI paths that ask only for logged-in
// state. The richer `/api/agents` payload is authoritative for install/auth
// gating.
function authStatus(agentKey) {
  const status = getAgentStatuses()[agentKey];
  return status ? status.authed === true : null;
}

module.exports = { authStatus };
