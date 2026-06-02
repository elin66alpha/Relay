'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const TOKENS_FILE = path.join(__dirname, '..', 'tokens.json');

function readTokenRecords() {
  try {
    const decoded = JSON.parse(fs.readFileSync(TOKENS_FILE, 'utf-8'));
    return Array.isArray(decoded) ? decoded.filter((item) => item && item.token) : [];
  } catch (_err) {
    return [];
  }
}

function writeTokenRecords(records) {
  fs.writeFileSync(TOKENS_FILE, `${JSON.stringify(records, null, 2)}\n`, {
    mode: 0o600,
  });
}

function activeTokenRecords() {
  return readTokenRecords().filter(
    (record) => record && !record.revoked && String(record.token || '').trim(),
  );
}

function hasConfiguredToken() {
  return activeTokenRecords().length > 0;
}

function isTokenAllowed(token) {
  const clean = String(token || '').trim();
  if (!clean) return false;
  return activeTokenRecords().some((record) => clean === String(record.token));
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
