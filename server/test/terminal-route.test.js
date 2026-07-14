'use strict';

const assert = require('node:assert/strict');
const { after, before, test } = require('node:test');
const express = require('express');

const createTerminalRouter = require('../routes/terminal');

let server;
let base;
let received;

before(async () => {
  const app = express();
  app.use(express.json());
  app.use(
    createTerminalRouter({
      bearerToken: () => 'device-token',
      tokenRecordForToken: () => ({ id: 'record-1', revoked: false }),
      terminalManager: {
        createTicket(input) {
          received = input;
          return { ticket: 'short-ticket', expiresInMs: 30000 };
        },
      },
    }),
  );
  await new Promise((resolve) => {
    server = app.listen(0, '127.0.0.1', resolve);
  });
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server && server.close());

test('terminal route scopes a ticket to the authenticated token record', async () => {
  const response = await fetch(`${base}/api/terminal/ticket`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ cols: 101, rows: 37 }),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(received, { tokenId: 'record-1', cols: 101, rows: 37 });
  assert.deepEqual(await response.json(), {
    ok: true,
    ticket: 'short-ticket',
    expiresInMs: 30000,
  });
});
