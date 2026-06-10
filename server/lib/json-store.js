'use strict';

// Shared JSON-file store used by the small persistence modules (tokens, agent
// sessions, chat sessions, agent settings, cards, quota schedules). It folds
// three concerns that were previously copy-pasted into each module:
//
//   * an in-memory cache keyed by the file's size+mtime, so repeated reads on a
//     hot path (e.g. token checks on every request) avoid re-parsing the file,
//     while an external writer (the `npm run credential` script writes
//     tokens.json from a separate process) is still picked up because its write
//     changes the stamp;
//   * atomic writes via a temp file + rename, so a crash mid-write can't leave a
//     truncated JSON file behind;
//   * a tolerant load that returns a fresh copy of `defaultValue` when the file
//     is missing or corrupt.
//
// `pretty`/`trailingNewline` preserve each caller's existing on-disk format so
// adopting the store produces no spurious file churn.

const fs = require('fs');

function createJsonStore(
  filePath,
  { defaultValue = {}, pretty = false, trailingNewline = false, mode = 0o600 } = {},
) {
  let cache = null;
  let stamp = null;

  function freshDefault() {
    return defaultValue === undefined
      ? undefined
      : JSON.parse(JSON.stringify(defaultValue));
  }

  function currentStamp() {
    try {
      const s = fs.statSync(filePath);
      return `${s.size}:${s.mtimeMs}`;
    } catch (_err) {
      return 'missing';
    }
  }

  // Returns the cached parsed value when the file is unchanged since the last
  // read, otherwise re-reads. The returned object is the live cache: callers
  // that mutate it must call save(), or use mutate() which pairs the two.
  function load() {
    const now = currentStamp();
    if (cache !== null && now === stamp) return cache;
    try {
      cache = JSON.parse(fs.readFileSync(filePath, 'utf-8'));
    } catch (_err) {
      cache = freshDefault();
    }
    stamp = now;
    return cache;
  }

  function serialize(data) {
    const body = pretty
      ? JSON.stringify(data, null, 2)
      : JSON.stringify(data);
    return trailingNewline ? `${body}\n` : body;
  }

  function save(data) {
    const text = serialize(data);
    const tmp = `${filePath}.tmp`;
    fs.writeFileSync(tmp, text, { mode });
    fs.renameSync(tmp, filePath);
    cache = data;
    stamp = currentStamp();
    return data;
  }

  // load() the current value, hand it to the mutator, then persist. Guarantees a
  // mutated value never lingers in the cache unsaved.
  function mutate(mutator) {
    const data = load();
    const result = mutator(data);
    save(data);
    return result;
  }

  function invalidate() {
    cache = null;
    stamp = null;
  }

  return { load, save, mutate, invalidate };
}

module.exports = { createJsonStore };
