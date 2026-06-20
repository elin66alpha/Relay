'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { randomUUID } = require('crypto');

const { clearAgentStatusCache } = require('./agent-status');

const PROVIDER_RE = /^[a-z0-9][a-z0-9._-]{0,80}$/i;

function ensureDir(dirPath, mode = 0o700) {
  fs.mkdirSync(dirPath, { recursive: true, mode });
  try {
    fs.chmodSync(dirPath, mode);
  } catch (_err) {
    // Best effort on filesystems that do not support POSIX modes.
  }
}

function atomicWrite(filePath, text, mode = 0o600) {
  ensureDir(path.dirname(filePath));
  const tmp = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(tmp, text, { mode });
  fs.renameSync(tmp, filePath);
  try {
    fs.chmodSync(filePath, mode);
  } catch (_err) {
    // Best effort on filesystems that do not support POSIX modes.
  }
}

function readJson(filePath, fallback) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (_err) {
    return fallback;
  }
}

function validateProvider(provider) {
  const value = String(provider || '').trim();
  if (!PROVIDER_RE.test(value)) {
    const err = new Error('provider is invalid');
    err.code = 'INVALID_PROVIDER';
    throw err;
  }
  return value;
}

function updateModelProviderYaml(text, provider) {
  const lines = String(text || '').split(/\r?\n/);
  let modelIndex = -1;
  let modelValue = '';
  for (let i = 0; i < lines.length; i += 1) {
    const match = /^model\s*:\s*(.*)$/.exec(lines[i]);
    if (match) {
      modelIndex = i;
      modelValue = match[1].trim();
      break;
    }
  }
  if (modelIndex === -1) {
    const prefix = lines.length && lines[lines.length - 1] !== '' ? [''] : [];
    return [...lines, ...prefix, 'model:', `  provider: ${provider}`].join('\n');
  }
  if (modelValue) {
    lines[modelIndex] = 'model:';
    lines.splice(modelIndex + 1, 0, `  default: ${modelValue}`, `  provider: ${provider}`);
    return lines.join('\n');
  }
  let insertAt = modelIndex + 1;
  for (let i = modelIndex + 1; i < lines.length; i += 1) {
    if (/^\S/.test(lines[i]) && lines[i].trim() !== '') break;
    if (/^\s+provider\s*:/.test(lines[i])) {
      lines[i] = `  provider: ${provider}`;
      return lines.join('\n');
    }
    insertAt = i + 1;
  }
  lines.splice(insertAt, 0, `  provider: ${provider}`);
  return lines.join('\n');
}

function writeHermesApiKey({
  provider,
  apiKey,
  label = 'Relay',
  homeDir = os.homedir(),
  now = () => new Date(),
  uuid = randomUUID,
} = {}) {
  const providerId = validateProvider(provider);
  const key = String(apiKey || '').trim();
  if (!key) {
    const err = new Error('apiKey is required');
    err.code = 'API_KEY_REQUIRED';
    throw err;
  }

  const hermesDir = path.join(homeDir, '.hermes');
  const authPath = path.join(hermesDir, 'auth.json');
  const configPath = path.join(hermesDir, 'config.yaml');
  const auth = readJson(authPath, { version: 1, providers: {} });
  auth.version = auth.version || 1;
  const pool = auth.credential_pool && typeof auth.credential_pool === 'object'
    ? auth.credential_pool
    : {};
  auth.credential_pool = pool;
  const entries = Array.isArray(pool[providerId]) ? pool[providerId] : [];
  pool[providerId] = [
    {
      id: `relay-${uuid()}`,
      source: 'manual:api_key',
      auth_type: 'api_key',
      label: String(label || 'Relay').trim() || 'Relay',
      access_token: key,
      created_at: now().toISOString(),
      last_status: 'ok',
    },
    ...entries.filter((entry) => entry && entry.source !== 'manual:api_key'),
  ];
  atomicWrite(authPath, `${JSON.stringify(auth, null, 2)}\n`);

  let configText = '';
  try {
    configText = fs.readFileSync(configPath, 'utf8');
  } catch (_err) {
    configText = '';
  }
  atomicWrite(configPath, `${updateModelProviderYaml(configText, providerId)}\n`);
  clearAgentStatusCache();
  return { provider: providerId, authPath, configPath };
}

module.exports = {
  updateModelProviderYaml,
  writeHermesApiKey,
};
