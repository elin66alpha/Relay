'use strict';

// A local setup status bridge. Never emit stored bearer tokens or CLI accounts.
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });
const { getAgentStatuses } = require('../lib/agent-status');
const { listTokenSummaries } = require('../lib/tokens');
const states = getAgentStatuses();
const definitions = [
  ['claude', 'Claude Code', 'claude'],
  ['codex', 'Codex', 'codex login --device-auth'],
  ['cursor', 'Cursor', 'agent login'],
  ['opencode', 'OpenCode', 'opencode auth login'],
  ['hermes', 'Hermes', 'hermes setup'],
];
console.log(JSON.stringify({
  agents: definitions.map(([key, label, login]) => ({
    key, label, login,
    installed: !!states[key]?.installed,
    authed: !!states[key]?.authed,
  })),
  tokens: listTokenSummaries(),
}));
