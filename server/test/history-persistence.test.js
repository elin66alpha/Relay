'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { after, test } = require('node:test');
const { setTimeout: delay } = require('node:timers/promises');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-history-persistence-'));
after(() => {
  delete process.env.RELAY_HISTORY_FILE;
  fs.rmSync(root, { recursive: true, force: true });
});

// history.js reads RELAY_HISTORY_FILE once at load, so each case loads its own copy.
function freshHistory() {
  const dir = fs.mkdtempSync(path.join(root, 'case-'));
  const file = path.join(dir, 'chat-history.json');
  process.env.RELAY_HISTORY_FILE = file;
  delete require.cache[require.resolve('../lib/history')];
  return { file, dir, history: require('../lib/history') };
}

async function until(check, timeoutMs = 10000) {
  const end = Date.now() + timeoutMs;
  while (!check()) {
    if (Date.now() > end) throw new Error('timed out waiting for the history file');
    await delay(25);
  }
}

const asideFiles = (file) =>
  fs.readdirSync(path.dirname(file)).filter((name) => name.startsWith(`${path.basename(file)}.corrupt-`));
const message = (id, content = id) => ({ id, role: 'assistant', content });

test('a missing file starts empty and the first flush creates it', () => {
  const { file, history } = freshHistory();
  assert.deepEqual(history.readHistory('/w\u0000claude'), []);
  history.upsertHistoryMessage('/w\u0000claude', message('m1'));
  history.flushHistory();
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { '/w\u0000claude': [message('m1')] });
  assert.deepEqual(asideFiles(file), []);
});

test('a valid file is read back and kept when messages are added', () => {
  const { file, history } = freshHistory();
  fs.writeFileSync(file, JSON.stringify({ old: [message('o1')] }));
  assert.deepEqual(history.readHistory('old'), [message('o1')]);
  history.upsertHistoryMessage('new', message('n1'));
  history.flushHistory();
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), {
    old: [message('o1')],
    new: [message('n1')],
  });
  assert.deepEqual(asideFiles(file), []);
});

test('a corrupt file is set aside with its bytes and history starts empty', () => {
  const { file, history } = freshHistory();
  const damaged = '{"old":[{"id":"o1","content":"half a wri';
  fs.writeFileSync(file, damaged);
  assert.deepEqual(history.readHistory('old'), []);
  history.upsertHistoryMessage('new', message('n1'));
  history.flushHistory();
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { new: [message('n1')] });
  const aside = asideFiles(file);
  assert.equal(aside.length, 1);
  assert.equal(fs.readFileSync(path.join(path.dirname(file), aside[0]), 'utf8'), damaged);
});

test('a history path that cannot be read as a file is set aside, not overwritten', () => {
  const { file, history } = freshHistory();
  fs.mkdirSync(file);
  fs.writeFileSync(path.join(file, 'marker'), 'kept');
  assert.deepEqual(history.readHistory('old'), []);
  history.upsertHistoryMessage('new', message('n1'));
  history.flushHistory();
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { new: [message('n1')] });
  const aside = asideFiles(file);
  assert.equal(aside.length, 1);
  assert.equal(fs.readFileSync(path.join(path.dirname(file), aside[0], 'marker'), 'utf8'), 'kept');
});

// Enough scopes (about 8 MB) that the background write needs many chunks.
function fillScopes(history, expected) {
  const body = 'x'.repeat(1000);
  for (let s = 0; s < 400; s += 1) {
    const key = `/w${s}\u0000claude`;
    expected[key] = [];
    for (let i = 0; i < 20; i += 1) {
      const item = message(`m${i}`, body);
      expected[key].push(item);
      history.upsertHistoryMessage(key, item);
    }
  }
}

test('the background write saves exactly the compact JSON of the history', async () => {
  const { file, history } = freshHistory();
  const expected = {};
  fillScopes(history, expected);
  await until(() => fs.existsSync(file) && fs.readFileSync(file, 'utf8') === JSON.stringify(expected));
});

test('a message added during a background write still reaches the file', async () => {
  const { file, history } = freshHistory();
  const expected = {};
  fillScopes(history, expected);
  await delay(350);
  const late = message('late');
  expected.late = [late];
  history.upsertHistoryMessage('late', late);
  await until(() => fs.existsSync(file) && fs.readFileSync(file, 'utf8') === JSON.stringify(expected));
});
