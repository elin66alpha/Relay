'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');

const CLAUDE_CREDS_PATH = path.join(os.homedir(), '.claude', '.credentials.json');
const CLAUDE_USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const CLAUDE_TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
const CLAUDE_CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const CLAUDE_OAUTH_BETA = 'oauth-2025-04-20';

const CODEX_AUTH = path.join(os.homedir(), '.codex', 'auth.json');
const CODEX_CONFIG = path.join(os.homedir(), '.codex', 'config.toml');
const CODEX_URL = 'https://chatgpt.com/backend-api/codex/responses';
const CODEX_CACHE_MS = 60_000;

let codexCache = { at: 0, value: null };

function readClaudeCreds() {
  const raw = fs.readFileSync(CLAUDE_CREDS_PATH, 'utf-8');
  return JSON.parse(raw);
}

function httpJson(method, url, headers, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const opts = { method, headers: { ...headers } };
    if (data) {
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['Content-Length'] = Buffer.byteLength(data);
    }
    const req = https.request(url, opts, (res) => {
      let buffer = '';
      res.on('data', (chunk) => {
        buffer += chunk;
      });
      res.on('end', () => {
        let parsed = null;
        try {
          parsed = JSON.parse(buffer);
        } catch (_err) {
          // Keep raw response.
        }
        resolve({ status: res.statusCode, body: parsed, raw: buffer });
      });
    });
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

async function refreshClaudeToken() {
  const creds = readClaudeCreds();
  const oauth = creds.claudeAiOauth || {};
  if (!oauth.refreshToken) {
    throw new Error('Claude credentials are missing refreshToken. Run claude login again.');
  }

  const { status, body } = await httpJson('POST', CLAUDE_TOKEN_URL, {}, {
    grant_type: 'refresh_token',
    refresh_token: oauth.refreshToken,
    client_id: CLAUDE_CLIENT_ID,
  });

  if (status !== 200 || !body || !body.access_token) {
    throw new Error(`Failed to refresh Claude token (HTTP ${status}).`);
  }

  oauth.accessToken = body.access_token;
  if (body.refresh_token) oauth.refreshToken = body.refresh_token;
  if (body.expires_in) oauth.expiresAt = Date.now() + body.expires_in * 1000;
  creds.claudeAiOauth = oauth;

  const tmp = `${CLAUDE_CREDS_PATH}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(creds), { mode: 0o600 });
  fs.renameSync(tmp, CLAUDE_CREDS_PATH);
  return oauth.accessToken;
}

async function getValidClaudeToken() {
  const oauth = readClaudeCreds().claudeAiOauth || {};
  if (!oauth.accessToken) {
    throw new Error('Claude accessToken was not found. Run claude login.');
  }
  if (oauth.expiresAt && Date.now() > oauth.expiresAt - 60_000) {
    return refreshClaudeToken();
  }
  return oauth.accessToken;
}

async function callClaudeUsage(token) {
  return httpJson('GET', CLAUDE_USAGE_URL, {
    Authorization: `Bearer ${token}`,
    'anthropic-beta': CLAUDE_OAUTH_BETA,
    'User-Agent': 'claude-cli',
    Accept: 'application/json',
  });
}

async function getClaudeUsage() {
  let token = await getValidClaudeToken();
  let res = await callClaudeUsage(token);
  if (res.status === 401) {
    token = await refreshClaudeToken();
    res = await callClaudeUsage(token);
  }
  if (res.status !== 200 || !res.body) {
    throw new Error(`Claude usage query failed (HTTP ${res.status}).`);
  }
  return {
    data: res.body,
    subscriptionType: (readClaudeCreds().claudeAiOauth || {}).subscriptionType,
  };
}

function httpHeadersOnly(url, headers, bodyStr) {
  return new Promise((resolve, reject) => {
    const opts = { method: 'POST', headers: { ...headers } };
    opts.headers['Content-Type'] = 'application/json';
    opts.headers['Content-Length'] = Buffer.byteLength(bodyStr);
    const req = https.request(url, opts, (res) => {
      const out = { status: res.statusCode, headers: res.headers };
      res.destroy();
      resolve(out);
    });
    req.on('error', reject);
    req.write(bodyStr);
    req.end();
  });
}

function firstHeader(headers, key) {
  const value = headers[key];
  return Array.isArray(value) ? value[0] : value;
}

function readCodexModel() {
  try {
    const match = /^\s*model\s*=\s*"([^"]+)"/m.exec(
      fs.readFileSync(CODEX_CONFIG, 'utf-8'),
    );
    if (match) return match[1];
  } catch (_err) {
    // Use default.
  }
  return 'gpt-5.5';
}

async function getCodexUsage() {
  if (codexCache.value && Date.now() - codexCache.at < CODEX_CACHE_MS) {
    return codexCache.value;
  }

  const auth = JSON.parse(fs.readFileSync(CODEX_AUTH, 'utf-8'));
  const token = auth.tokens && auth.tokens.access_token;
  const accountId = (auth.tokens && auth.tokens.account_id) || '';
  if (!token) {
    throw new Error('Codex credentials were not found. Run codex login.');
  }

  const body = JSON.stringify({
    model: readCodexModel(),
    instructions: 'You are a helper.',
    input: [
      {
        type: 'message',
        role: 'user',
        content: [{ type: 'input_text', text: 'hi' }],
      },
    ],
    tools: [],
    tool_choice: 'auto',
    parallel_tool_calls: false,
    store: false,
    stream: true,
    include: [],
    reasoning: { effort: 'low' },
  });

  const { status, headers } = await httpHeadersOnly(CODEX_URL, {
    Authorization: `Bearer ${token}`,
    'chatgpt-account-id': accountId,
    'OpenAI-Beta': 'responses=experimental',
    originator: 'codex_cli_rs',
    'User-Agent': 'codex_cli_rs/0.132.0',
    Accept: 'text/event-stream',
  }, body);

  if (status === 401) {
    throw new Error('Codex token expired. Send one Codex CLI message in the terminal, then retry.');
  }
  const hasQuotaHeaders = Boolean(
    firstHeader(headers, 'x-codex-primary-used-percent') ||
      firstHeader(headers, 'x-codex-secondary-used-percent') ||
      firstHeader(headers, 'x-codex-primary-reset-at') ||
      firstHeader(headers, 'x-codex-secondary-reset-at'),
  );
  if (status !== 200 && status !== 429 && !hasQuotaHeaders) {
    throw new Error(`Codex usage query failed (HTTP ${status}).`);
  }

  const num = (key) => {
    const value = firstHeader(headers, key);
    return value == null || value === '' ? null : Number(value);
  };
  const iso = (key) => {
    const value = num(key);
    return value ? new Date(value * 1000).toISOString() : null;
  };
  const activeLimit = String(firstHeader(headers, 'x-codex-active-limit') || '');
  const primaryUsed = num('x-codex-primary-used-percent');
  const secondaryUsed = num('x-codex-secondary-used-percent');
  const value = {
    plan: firstHeader(headers, 'x-codex-plan-type') || activeLimit || 'Unknown',
    five_hour: {
      utilization:
        primaryUsed == null && status === 429 && (!activeLimit || activeLimit.includes('primary'))
          ? 100
          : primaryUsed,
      resets_at: iso('x-codex-primary-reset-at'),
    },
    seven_day: {
      utilization:
        secondaryUsed == null && status === 429 && activeLimit.includes('secondary')
          ? 100
          : secondaryUsed,
      resets_at: iso('x-codex-secondary-reset-at'),
    },
  };
  codexCache = { at: Date.now(), value };
  return value;
}

function clampPercent(value) {
  if (value == null || !Number.isFinite(Number(value))) return null;
  return Math.max(0, Math.min(100, Number(value)));
}

function quotaItem(key, label, block) {
  const usedPercent = clampPercent(block && block.utilization);
  return {
    key,
    label,
    usedPercent,
    remainingPercent: usedPercent == null ? null : Math.max(0, 100 - usedPercent),
    resetsAt: (block && block.resets_at) || null,
  };
}

async function buildUsageReport() {
  const agents = [];
  try {
    const { data, subscriptionType } = await getClaudeUsage();
    agents.push({
      key: 'claude',
      label: 'Claude Code',
      available: true,
      detail: subscriptionType || '',
      quotas: [
        quotaItem('five_hour', '5 hour quota', data.five_hour),
        quotaItem('seven_day', 'Weekly quota', data.seven_day),
      ],
    });
  } catch (err) {
    agents.push({
      key: 'claude',
      label: 'Claude Code',
      available: true,
      error: err.message,
      quotas: [],
    });
  }

  try {
    const usage = await getCodexUsage();
    agents.push({
      key: 'codex',
      label: 'Codex',
      available: true,
      detail: usage.plan || '',
      quotas: [
        quotaItem('five_hour', '5 hour quota', usage.five_hour),
        quotaItem('seven_day', 'Weekly quota', usage.seven_day),
      ],
    });
  } catch (err) {
    agents.push({
      key: 'codex',
      label: 'Codex',
      available: true,
      error: err.message,
      quotas: [],
    });
  }

  agents.push({
    key: 'agy',
    label: 'Antigravity',
    available: false,
    unavailableReason: 'not_available_yet',
    quotas: [],
  });

  return {
    createdAt: new Date().toISOString(),
    mode: 'remaining',
    agents,
  };
}

module.exports = {
  getClaudeUsage,
  getAccountUsage: getClaudeUsage,
  getCodexUsage,
  buildUsageReport,
};
