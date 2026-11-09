#!/usr/bin/env node
'use strict';

const readline = require('node:readline');

const { version } = require('./package.json');
const { decryptCredential } = require('./lib/credential');
const { createMcpHandler } = require('./lib/protocol');
const { createRelayClient } = require('./lib/relay-client');
const { createTools } = require('./lib/tools');

const INSTRUCTIONS = [
  'Relay drives the coding agents (Claude Code, Codex, Cursor, OpenCode, Antigravity, Hermes) on one backend machine.',
  'Start with relay_status. Every agent runs in this connection\'s workdir (relay_workdir); conversations are shared with the user\'s Relay app.',
  'relay_chat returns the reply if it finishes within waitSeconds; otherwise poll relay_task with the returned requestId, agent, sessionId and workdir.',
  'Change model or reasoning effort with relay_agent_options then relay_agent_settings; check quota with relay_usage.',
].join(' ');

const name = String(process.env.RELAY_MCP_NAME || 'mcp').trim().replace(/[^A-Za-z0-9._-]/g, '-').slice(0, 100) || 'mcp';
const state = { workdir: String(process.env.RELAY_WORKDIR || '').trim() };

// Decrypt once at start with the same envelope and password the app uses. A
// failure keeps the server up so each tool call explains what to fix.
let client = null;
let machineName = '';
let credentialError = null;
try {
  const machine = decryptCredential(process.env.RELAY_CREDENTIAL, process.env.RELAY_CREDENTIAL_PASSPHRASE);
  machineName = machine.name;
  client = createRelayClient({
    baseUrl: machine.baseUrl,
    token: machine.token,
    deviceId: `relay-mcp-${name}`,
    deviceName: `Relay MCP (${name})`,
    getWorkdir: () => state.workdir,
  });
  process.stderr.write(`relay-mcp ${version}: connected to ${machine.name} at ${machine.baseUrl}\n`);
} catch (err) {
  credentialError = err;
  process.stderr.write(`relay-mcp ${version}: ${err.message}\n`);
}

const handle = createMcpHandler({
  name: 'relay',
  version,
  instructions: INSTRUCTIONS,
  tools: createTools({
    getClient() {
      if (credentialError) throw credentialError;
      return client;
    },
    state,
    machineName,
  }),
});

function write(message) {
  if (message) process.stdout.write(`${JSON.stringify(message)}\n`);
}

const lines = readline.createInterface({ input: process.stdin, terminal: false });
lines.on('line', (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch (_err) {
    write({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } });
    return;
  }
  handle(message).then(write, (err) => process.stderr.write(`relay-mcp: ${err.stack || err}\n`));
});
lines.on('close', () => process.exit(0));
