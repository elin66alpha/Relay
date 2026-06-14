'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { createJsonStore } = require('../lib/json-store');

function scratchFile(name = 'store.json') {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-jsonstore-'));
  return { dir, file: path.join(dir, name) };
}

function cleanup(dir) {
  fs.rmSync(dir, { recursive: true, force: true });
}

test('load returns the default value when the file is missing', () => {
  const { dir, file } = scratchFile();
  try {
    const store = createJsonStore(file, { defaultValue: [] });
    assert.deepEqual(store.load(), []);
  } finally {
    cleanup(dir);
  }
});

test('the default value is deep-copied so a mutation cannot poison the shared default', () => {
  const { dir, file } = scratchFile();
  try {
    const shared = { items: [1, 2] };
    const store = createJsonStore(file, { defaultValue: shared });
    const loaded = store.load();
    loaded.items.push(999);

    // A fresh store reading the same (still missing) file gets the pristine
    // default, proving load() handed out a copy rather than the original.
    const other = createJsonStore(file, { defaultValue: shared });
    assert.deepEqual(other.load(), { items: [1, 2] });
    assert.deepEqual(shared, { items: [1, 2] });
  } finally {
    cleanup(dir);
  }
});

test('save round-trips through disk and writes atomically (no .tmp left behind)', () => {
  const { dir, file } = scratchFile();
  try {
    const store = createJsonStore(file, { defaultValue: {} });
    store.save({ a: 1, b: 'two' });

    // The on-disk file parses back to the saved value...
    assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf-8')), { a: 1, b: 'two' });
    // ...and the temp file used for the atomic rename is gone.
    assert.equal(fs.existsSync(`${file}.tmp`), false);

    // A brand-new store instance reads the persisted value.
    const reopened = createJsonStore(file, { defaultValue: {} });
    assert.deepEqual(reopened.load(), { a: 1, b: 'two' });
  } finally {
    cleanup(dir);
  }
});

test('save respects the requested file mode (0600 — secrets stay owner-only)', { skip: process.platform === 'win32' }, () => {
  const { dir, file } = scratchFile();
  try {
    const store = createJsonStore(file, { defaultValue: [], mode: 0o600 });
    store.save([{ token: 'secret' }]);
    const mode = fs.statSync(file).mode & 0o777;
    assert.equal(mode, 0o600, `expected 0600, got ${mode.toString(8)}`);
  } finally {
    cleanup(dir);
  }
});

test('pretty/trailingNewline preserve the on-disk format', () => {
  const { dir, file } = scratchFile();
  try {
    const store = createJsonStore(file, {
      defaultValue: [],
      pretty: true,
      trailingNewline: true,
    });
    store.save([{ id: 1 }]);
    const text = fs.readFileSync(file, 'utf-8');
    assert.equal(text, `${JSON.stringify([{ id: 1 }], null, 2)}\n`);
  } finally {
    cleanup(dir);
  }
});

test('load is tolerant of a corrupt file and falls back to the default', () => {
  const { dir, file } = scratchFile();
  try {
    fs.writeFileSync(file, '{ this is not json ');
    const store = createJsonStore(file, { defaultValue: { ok: true } });
    assert.deepEqual(store.load(), { ok: true });
  } finally {
    cleanup(dir);
  }
});

test('an external write (changed stamp) is picked up on the next load', () => {
  const { dir, file } = scratchFile();
  try {
    const store = createJsonStore(file, { defaultValue: {} });
    store.save({ v: 1 });
    assert.deepEqual(store.load(), { v: 1 });

    // Simulate a separate process rewriting the file with different content
    // (different size => different stamp), as `npm run credential` does.
    fs.writeFileSync(file, JSON.stringify({ v: 2, extra: 'grown' }));
    assert.deepEqual(store.load(), { v: 2, extra: 'grown' });
  } finally {
    cleanup(dir);
  }
});

test('mutate loads, applies, and persists in one step', () => {
  const { dir, file } = scratchFile();
  try {
    const store = createJsonStore(file, { defaultValue: { count: 0 } });
    const result = store.mutate((data) => {
      data.count += 5;
      return 'done';
    });
    assert.equal(result, 'done');
    // Persisted, not just cached: a fresh instance sees it.
    const reopened = createJsonStore(file, { defaultValue: { count: 0 } });
    assert.deepEqual(reopened.load(), { count: 5 });
  } finally {
    cleanup(dir);
  }
});

test('invalidate forces the next load to re-read from disk', () => {
  const { dir, file } = scratchFile();
  try {
    const store = createJsonStore(file, { defaultValue: {} });
    store.save({ v: 1 });
    // Overwrite with the SAME byte length so size+mtime may collide within the
    // timer resolution; invalidate() must still force a re-read.
    fs.writeFileSync(file, JSON.stringify({ v: 9 }));
    store.invalidate();
    assert.deepEqual(store.load(), { v: 9 });
  } finally {
    cleanup(dir);
  }
});
