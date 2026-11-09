'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const path = require('node:path');
const test = require('node:test');

const { createMcpHandler } = require('../lib/protocol');

const handle = createMcpHandler({
  name: 'relay',
  version: '0.0.0',
  instructions: 'hi',
  tools: [
    {
      name: 'echo',
      description: 'echo',
      inputSchema: { type: 'object' },
      handler: async (args) => ({ said: args.text }),
    },
    {
      name: 'fail',
      description: 'fail',
      inputSchema: { type: 'object' },
      handler: async () => {
        const err = new Error('session limit reached');
        err.code = 'SESSION_LIMIT_REACHED';
        throw err;
      },
    },
  ],
});

test('negotiates the protocol version', async () => {
  const known = await handle({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } });
  assert.equal(known.result.protocolVersion, '2025-06-18');
  assert.deepEqual(known.result.capabilities, { tools: {} });
  const unknown = await handle({ jsonrpc: '2.0', id: 2, method: 'initialize', params: { protocolVersion: '1999-01-01' } });
  assert.equal(unknown.result.protocolVersion, '2025-11-25');
});

test('lists and calls tools; tool errors come back as isError text', async () => {
  const list = await handle({ jsonrpc: '2.0', id: 1, method: 'tools/list' });
  assert.deepEqual(list.result.tools.map((tool) => tool.name), ['echo', 'fail']);
  const ok = await handle({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'echo', arguments: { text: 'x' } } });
  assert.deepEqual(JSON.parse(ok.result.content[0].text), { said: 'x' });
  const failed = await handle({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'fail' } });
  assert.equal(failed.result.isError, true);
  assert.match(failed.result.content[0].text, /SESSION_LIMIT_REACHED/);
});

test('ignores notifications and rejects unknown methods', async () => {
  assert.equal(await handle({ jsonrpc: '2.0', method: 'notifications/initialized' }), null);
  const missing = await handle({ jsonrpc: '2.0', id: 9, method: 'resources/list' });
  assert.equal(missing.error.code, -32601);
});

test('stdio server answers without a credential and explains what is missing', async () => {
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'index.js')], {
    env: { ...process.env, RELAY_CREDENTIAL: '', RELAY_CREDENTIAL_PASSPHRASE: '' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const replies = [];
  let buffer = '';
  const done = new Promise((resolve) => {
    child.stdout.on('data', (chunk) => {
      buffer += chunk;
      const lines = buffer.split('\n');
      buffer = lines.pop();
      for (const line of lines) replies.push(JSON.parse(line));
      if (replies.length === 2) resolve();
    });
  });
  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })}\n`);
  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'relay_status', arguments: {} } })}\n`);
  await done;
  child.kill();
  assert.equal(replies[0].result.serverInfo.name, 'relay');
  assert.equal(replies[1].result.isError, true);
  assert.match(replies[1].result.content[0].text, /RELAY_CREDENTIAL/);
});
