'use strict';

// The setup menus' view of this backend (scripts/install/unix/setup.sh and
// scripts/install/windows/setup.ps1), so they list the agents and their
// install state the backend itself sees. JSON by default; `--agents` prints
// one tab-separated `key label installed login` line per agent for bash.
// Never emit stored bearer tokens or CLI accounts.
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
  ['agy', 'Antigravity', 'agy acp --login'],
  ['hermes', 'Hermes', 'hermes setup'],
];
const agents = definitions.map(([key, label, login]) => ({
  key, label, login,
  installed: !!states[key]?.installed,
  authed: states[key]?.authed ?? null,
}));
if (process.argv.includes('--agents')) {
  for (const agent of agents) {
    console.log([agent.key, agent.label, agent.installed ? 1 : 0, agent.login].join('\t'));
  }
} else {
  console.log(JSON.stringify({ agents, tokens: listTokenSummaries() }));
}
