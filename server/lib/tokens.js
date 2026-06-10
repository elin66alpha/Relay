'use strict';

const crypto = require('crypto');
const path = require('path');

const { createJsonStore } = require('./json-store');

const TOKENS_FILE = path.join(__dirname, '..', 'tokens.json');

// Cached, atomic store. The `npm run credential` script writes tokens.json from
// a separate process; its write changes the file stamp, so this server's cached
// copy is refreshed on the next read instead of going stale.
const store = createJsonStore(TOKENS_FILE, {
  defaultValue: [],
  pretty: true,
  trailingNewline: true,
});

function readTokenRecords() {
  const decoded = store.load();
  return Array.isArray(decoded) ? decoded.filter((item) => item && item.token) : [];
}

function writeTokenRecords(records) {
  store.save(records);
}

function activeTokenRecords() {
  return readTokenRecords().filter(
    (record) => record && !record.revoked && String(record.token || '').trim(),
  );
}

function hasConfiguredToken() {
  return activeTokenRecords().length > 0;
}

// Compare a presented token against each active token in constant time, so a
// timing side channel can't reveal how many leading characters matched. Hashing
// both sides first keeps timingSafeEqual's equal-length requirement regardless
// of the candidate's length.
function tokenDigest(value) {
  return crypto.createHash('sha256').update(String(value)).digest();
}

function isTokenAllowed(token) {
  const clean = String(token || '').trim();
  if (!clean) return false;
  const candidate = tokenDigest(clean);
  let allowed = false;
  for (const record of activeTokenRecords()) {
    if (crypto.timingSafeEqual(candidate, tokenDigest(record.token))) {
      allowed = true;
    }
  }
  return allowed;
}

function tokenRecordForToken(token) {
  const clean = String(token || '').trim();
  if (!clean) return null;
  return readTokenRecords().find((record) => clean === String(record.token)) || null;
}

function createToken({ label }) {
  const token = crypto.randomBytes(32).toString('base64url');
  const record = {
    id: crypto.randomUUID(),
    token,
    label: String(label || 'Unnamed device').trim() || 'Unnamed device',
    createdAt: new Date().toISOString(),
    revoked: false,
  };
  const records = readTokenRecords();
  records.push(record);
  writeTokenRecords(records);
  return record;
}

function listTokenSummaries({ currentToken } = {}) {
  const current = tokenRecordForToken(currentToken);
  return readTokenRecords().map((record) => ({
    id: record.id || '',
    label: record.label || '',
    createdAt: record.createdAt || '',
    revoked: !!record.revoked,
    revokedAt: record.revokedAt || '',
    current: !!(current && current.id && record.id === current.id),
  }));
}

function revokeTokenById(id) {
  const target = String(id || '').trim();
  if (!target) return null;

  const records = readTokenRecords();
  const index = records.findIndex((record) => record.id === target);
  if (index === -1) return null;

  records[index] = {
    ...records[index],
    revoked: true,
    revokedAt: new Date().toISOString(),
  };
  writeTokenRecords(records);
  return records[index];
}

function revokeToken(idOrToken) {
  const target = String(idOrToken || '').trim();
  if (!target) return null;

  const records = readTokenRecords();
  const index = records.findIndex(
    (record) => record.id === target || record.token === target,
  );
  if (index === -1) return null;

  records[index] = {
    ...records[index],
    revoked: true,
    revokedAt: new Date().toISOString(),
  };
  writeTokenRecords(records);
  return records[index];
}

module.exports = {
  createToken,
  hasConfiguredToken,
  isTokenAllowed,
  listTokenSummaries,
  revokeToken,
  revokeTokenById,
  tokenRecordForToken,
};
