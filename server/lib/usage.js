'use strict';

const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');
const http = require('http');
const { createJsonStore } = require('./json-store');
const { cursorAuthFile, agyAuthFile, locateBin } = require('./cli-paths');

const CLAUDE_CREDS_PATH = path.join(os.homedir(), '.claude', '.credentials.json');
const CLAUDE_USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const CLAUDE_TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
const CLAUDE_MESSAGES_URL = 'https://api.anthropic.com/v1/messages';
const CLAUDE_CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const CLAUDE_OAUTH_BETA = 'oauth-2025-04-20';
const CLAUDE_API_VERSION = '2023-06-01';
// The keepalive ping is billed like any other Claude Code turn, so it uses a
// low-cost default model and the smallest possible completion. Deployments can
// override the model explicitly.
const CLAUDE_KEEPALIVE_MODEL =
  process.env.CLAUDE_KEEPALIVE_MODEL || 'claude-haiku-4-5';
const CLAUDE_CODE_SYSTEM_PROMPT =
  "You are Claude Code, Anthropic's official CLI for Claude.";

const CODEX_AUTH = path.join(os.homedir(), '.codex', 'auth.json');
const CODEX_CONFIG = path.join(os.homedir(), '.codex', 'config.toml');
const CODEX_URL = 'https://chatgpt.com/backend-api/codex/responses';
const CODEX_TOKEN_URL = 'https://auth.openai.com/oauth/token';
const CODEX_CLIENT_ID = 'app_EMoamEEZ73f0CkXaXp7hrann';
const CODEX_CACHE_MS = 60_000;
const CLAUDE_CACHE_MS = 60_000;
const USAGE_CACHE_FILE = path.join(__dirname, '..', 'usage-cache.json');
const usageCacheStore = createJsonStore(USAGE_CACHE_FILE, {
  pretty: true,
  trailingNewline: true,
});
const USAGE_BACKOFF_BASE_MS = parseInt(
  process.env.USAGE_BACKOFF_BASE_MS || '30000',
  10,
);
const USAGE_BACKOFF_MAX_MS = parseInt(
  process.env.USAGE_BACKOFF_MAX_MS || '900000',
  10,
);
// Hard timeout for every outbound usage/oauth request. Without it a stalled
// connection hangs /api/usage forever and permanently wedges the single-flight
// background refresh (its promise would never settle).
const USAGE_HTTP_TIMEOUT_MS = parseInt(
  process.env.USAGE_HTTP_TIMEOUT_MS || '15000',
  10,
);

function attachTimeout(req, url) {
  req.setTimeout(USAGE_HTTP_TIMEOUT_MS, () => {
    req.destroy(
      new UsageQueryError(
        `request to ${new URL(url).host} timed out after ${USAGE_HTTP_TIMEOUT_MS}ms`,
      ),
    );
  });
}

let codexCache = { at: 0, fetchedAt: '', value: null, stale: false };
let claudeCache = { at: 0, fetchedAt: '', value: null, stale: false };
let agyCache = { at: 0, fetchedAt: '', value: null, stale: false };
let cursorCache = { at: 0, fetchedAt: '', value: null, stale: false };
const usageBackoff = {
  agy: { until: 0, delayMs: 0, refreshPromise: null, credMtime: 0 },
  claude: { until: 0, delayMs: 0, refreshPromise: null, credMtime: 0 },
  codex: { until: 0, delayMs: 0, refreshPromise: null, credMtime: 0 },
  cursor: { until: 0, delayMs: 0, refreshPromise: null, credMtime: 0 },
};

// Claude/Codex quota credentials are shared with the live CLIs, which rotate
// their OAuth tokens in place. A failed query is almost always a transient auth
// race the CLI fixes by rewriting its credential file, so we remember the file's
// mtime at failure time: once it changes, the backoff is dropped and the next
// query retries immediately with the fresh token instead of serving stale.
const USAGE_CRED_FILES = {
  claude: CLAUDE_CREDS_PATH,
  codex: CODEX_AUTH,
  cursor: cursorAuthFile(),
  agy: agyAuthFile(),
};

function credentialMtimeMs(key) {
  const file = USAGE_CRED_FILES[key];
  if (!file) return 0;
  try {
    return fs.statSync(file).mtimeMs;
  } catch (_err) {
    return 0;
  }
}

class UsageQueryError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

function persistedRecord(key) {
  const record = usageCacheStore.load()[key];
  if (!record || typeof record !== 'object' || !record.value) return null;
  return {
    fetchedAt: String(record.fetchedAt || record.savedAt || ''),
    value: record.value,
  };
}

function stripUsageMetadata(value) {
  const { fetchedAt: _fetchedAt, stale: _stale, ...clean } = value || {};
  return clean;
}

function withUsageMetadata(record, stale) {
  return {
    ...record.value,
    fetchedAt: record.fetchedAt,
    stale,
  };
}

function rememberUsageSuccess(key, value, setMemoryCache) {
  const fetchedAt = new Date().toISOString();
  const record = {
    fetchedAt,
    value: stripUsageMetadata(value),
  };
  usageCacheStore.mutate((cache) => {
    cache[key] = record;
  });
  setMemoryCache({
    at: Date.now(),
    fetchedAt,
    value: record.value,
    stale: false,
  });
  usageBackoff[key].delayMs = 0;
  usageBackoff[key].until = 0;
  return withUsageMetadata(record, false);
}

function rememberBackoff(key, err) {
  const state = usageBackoff[key];
  const previous = state.delayMs > 0 ? state.delayMs : USAGE_BACKOFF_BASE_MS / 2;
  const delayMs = Math.min(
    USAGE_BACKOFF_MAX_MS,
    Math.max(1000, previous * 2),
  );
  state.delayMs = delayMs;
  state.until = Date.now() + delayMs;
  state.credMtime = credentialMtimeMs(key);
  const status = err && err.status ? ` HTTP ${err.status}` : '';
  console.warn(
    `[usage:${key}] query failed${status}; backing off for ` +
      `${Math.round(delayMs / 1000)}s: ${err.message}`,
  );
}

function memoryRecord(cache) {
  if (!cache.value) return null;
  return {
    fetchedAt: cache.fetchedAt,
    value: cache.value,
  };
}

function fallbackRecord(key, cache) {
  return persistedRecord(key) || memoryRecord(cache);
}

// One fetch per source at a time: concurrent callers (strip, quota page, other
// devices) share it instead of each starting its own request or CLI process.
function refreshUsage({ key, fetcher, setMemoryCache }) {
  const state = usageBackoff[key];
  if (!state.refreshPromise) {
    state.refreshPromise = (async () => {
      try {
        return rememberUsageSuccess(key, await fetcher(), setMemoryCache);
      } catch (err) {
        rememberBackoff(key, err);
        throw err;
      } finally {
        state.refreshPromise = null;
      }
    })();
  }
  return state.refreshPromise;
}

function scheduleRefresh(options) {
  refreshUsage(options).catch(() => {});
}

async function cachedUsage({
  key,
  ttlMs,
  getMemoryCache,
  setMemoryCache,
  fetcher,
}) {
  const now = Date.now();
  const cache = getMemoryCache();
  if (cache.value && !cache.stale && now - cache.at < ttlMs) {
    return withUsageMetadata(memoryRecord(cache), false);
  }

  const fallback = fallbackRecord(key, cache);
  if (!cache.value && fallback) {
    setMemoryCache({
      at: now,
      fetchedAt: fallback.fetchedAt,
      value: fallback.value,
      stale: true,
    });
    scheduleRefresh({ key, fetcher, setMemoryCache });
    return withUsageMetadata(fallback, true);
  }

  const state = usageBackoff[key];
  if (state.until > now && fallback) {
    // Still within the backoff window: only retry early if the CLI has rewritten
    // its credentials (token refreshed / re-login) since the failure. Otherwise
    // keep serving stale instead of hammering a still-failing API.
    if (credentialMtimeMs(key) <= state.credMtime) {
      return withUsageMetadata(fallback, true);
    }
    state.until = 0;
    state.delayMs = 0;
  }

  try {
    return await refreshUsage({ key, fetcher, setMemoryCache });
  } catch (err) {
    const latestFallback = fallbackRecord(key, getMemoryCache());
    if (latestFallback) return withUsageMetadata(latestFallback, true);
    throw err;
  }
}

function readClaudeCreds() {
  const raw = fs.readFileSync(CLAUDE_CREDS_PATH, 'utf-8');
  return JSON.parse(raw);
}

function httpJson(method, url, headers, body, timeoutMs) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const opts = { method, headers: { ...headers } };
    if (data) {
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['Content-Length'] = Buffer.byteLength(data);
    }
    const transport = new URL(url).protocol === 'http:' ? http : https;
    const req = transport.request(url, opts, (res) => {
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
    attachTimeout(req, url);
    if (timeoutMs) req.setTimeout(timeoutMs);
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

async function fetchClaudeUsage() {
  let token = await getValidClaudeToken();
  let res = await callClaudeUsage(token);
  if (res.status === 401) {
    token = await refreshClaudeToken();
    res = await callClaudeUsage(token);
  }
  if (res.status !== 200 || !res.body) {
    throw new UsageQueryError(
      `Claude usage query failed (HTTP ${res.status}).`,
      res.status,
    );
  }
  return {
    data: res.body,
    subscriptionType: (readClaudeCreds().claudeAiOauth || {}).subscriptionType,
  };
}

async function getClaudeUsage() {
  return cachedUsage({
    key: 'claude',
    ttlMs: CLAUDE_CACHE_MS,
    getMemoryCache: () => claudeCache,
    setMemoryCache: (cache) => {
      claudeCache = cache;
    },
    fetcher: fetchClaudeUsage,
  });
}

// Claude's five-hour window only exists while it is running: once it lapses the
// usage API reports `resets_at: null` until the next real turn, which the app can
// only show as "unknown". Codex avoids that because its quota probe *is* a live
// request; Claude's is a plain read, so we send the equivalent minimal turn
// ourselves to restart the window. One token on the configured keepalive model,
// using the same OAuth credential and Claude Code identity as the usage query.
async function callClaudeMessages(token) {
  return httpJson('POST', CLAUDE_MESSAGES_URL, {
    Authorization: `Bearer ${token}`,
    'anthropic-beta': CLAUDE_OAUTH_BETA,
    'anthropic-version': CLAUDE_API_VERSION,
    'User-Agent': 'claude-cli',
    Accept: 'application/json',
  }, {
    model: CLAUDE_KEEPALIVE_MODEL,
    max_tokens: 1,
    system: [{ type: 'text', text: CLAUDE_CODE_SYSTEM_PROMPT }],
    messages: [{ role: 'user', content: 'hi' }],
  });
}

async function primeClaudeSession() {
  let token = await getValidClaudeToken();
  let res = await callClaudeMessages(token);
  if (res.status === 401) {
    token = await refreshClaudeToken();
    res = await callClaudeMessages(token);
  }
  // 429 means the quota is already exhausted, which is itself a running window:
  // the ping did its job and the caller should not treat it as a failure.
  if (res.status !== 200 && res.status !== 429) {
    const detail =
      (res.body && res.body.error && res.body.error.message) || res.raw || '';
    throw new UsageQueryError(
      `Claude keepalive request failed (HTTP ${res.status}). ${detail}`.trim(),
      res.status,
    );
  }
  return { status: res.status, model: CLAUDE_KEEPALIVE_MODEL };
}

// Drop the in-memory TTL for one source so the next read re-queries the API.
// Used after the keepalive ping so the fresh `resets_at` is picked up at once
// instead of after the normal cache window.
function invalidateUsageCache(key) {
  const caches = {
    claude: () => claudeCache,
    codex: () => codexCache,
    cursor: () => cursorCache,
    agy: () => agyCache,
  };
  const cache = caches[key] && caches[key]();
  if (cache) cache.at = 0;
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
    attachTimeout(req, url);
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

// Codex shares ~/.codex/auth.json with the CLI. The access_token is short-lived,
// so when our quota probe sees a 401 we refresh it in place with the long-lived
// refresh_token (same OAuth flow the CLI uses) instead of forcing the user to go
// run a Codex message in a terminal. Mirrors refreshClaudeToken.
async function refreshCodexToken(auth) {
  const refreshToken = auth.tokens && auth.tokens.refresh_token;
  if (!refreshToken) {
    throw new Error('Codex credentials are missing refresh_token. Run codex login again.');
  }
  const { status, body } = await httpJson('POST', CODEX_TOKEN_URL, {}, {
    client_id: CODEX_CLIENT_ID,
    grant_type: 'refresh_token',
    refresh_token: refreshToken,
    scope: 'openid profile email',
  });
  if (status !== 200 || !body || !body.access_token) {
    throw new UsageQueryError(`Failed to refresh Codex token (HTTP ${status}).`, status);
  }
  auth.tokens = {
    ...auth.tokens,
    access_token: body.access_token,
    id_token: body.id_token || auth.tokens.id_token,
    refresh_token: body.refresh_token || refreshToken,
  };
  auth.last_refresh = new Date().toISOString();
  const tmp = `${CODEX_AUTH}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(auth, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, CODEX_AUTH);
  return auth.tokens.access_token;
}

function callCodexUsage(token, accountId, body) {
  return httpHeadersOnly(CODEX_URL, {
    Authorization: `Bearer ${token}`,
    'chatgpt-account-id': accountId,
    'OpenAI-Beta': 'responses=experimental',
    originator: 'codex_cli_rs',
    'User-Agent': 'codex_cli_rs/0.132.0',
    Accept: 'text/event-stream',
  }, body);
}

async function fetchCodexUsage() {
  const auth = JSON.parse(fs.readFileSync(CODEX_AUTH, 'utf-8'));
  let token = auth.tokens && auth.tokens.access_token;
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

  let { status, headers } = await callCodexUsage(token, accountId, body);
  if (status === 401) {
    token = await refreshCodexToken(auth);
    ({ status, headers } = await callCodexUsage(token, accountId, body));
  }
  const hasQuotaHeaders = Boolean(
    firstHeader(headers, 'x-codex-primary-used-percent') ||
      firstHeader(headers, 'x-codex-secondary-used-percent') ||
      firstHeader(headers, 'x-codex-primary-reset-at') ||
      firstHeader(headers, 'x-codex-secondary-reset-at'),
  );
  if (status !== 200 && !hasQuotaHeaders) {
    throw new UsageQueryError(`Codex usage query failed (HTTP ${status}).`, status);
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
  return {
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
}

async function getCodexUsage() {
  return cachedUsage({
    key: 'codex',
    ttlMs: CODEX_CACHE_MS,
    getMemoryCache: () => codexCache,
    setMemoryCache: (cache) => {
      codexCache = cache;
    },
    fetcher: fetchCodexUsage,
  });
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
    expired: false,
  };
}

// A stale cached quota whose reset time has already passed no longer reflects
// reality: the rolling window refreshed while the source was unreachable, so
// the cached utilization is meaningless — the real remaining is back near
// full. Flag those buckets `expired` so the client shows "window reset, awaiting
// refresh" instead of a misleading old percentage. Fresh (non-stale) data is
// never touched, even if its reset moment just passed, because it was just read.
function markExpiredQuotas(quotas, stale, nowMs = Date.now()) {
  if (!stale) return quotas;
  return quotas.map((quota) => {
    if (!quota || !quota.resetsAt) return quota;
    const resetMs = Date.parse(quota.resetsAt);
    if (Number.isFinite(resetMs) && resetMs <= nowMs) {
      return { ...quota, expired: true };
    }
    return quota;
  });
}

const CURSOR_API = 'https://api2.cursor.sh';
const CURSOR_PLAN_URL = `${CURSOR_API}/aiserver.v1.DashboardService/GetPlanInfo`;
const CURSOR_PERIOD_URL = `${CURSOR_API}/aiserver.v1.DashboardService/GetCurrentPeriodUsage`;
const CURSOR_EXCHANGE_URL = `${CURSOR_API}/auth/exchange_user_api_key`;

function cursorEpochIso(value) {
  const millis = Number(value);
  if (!Number.isFinite(millis) || millis <= 0) return null;
  return new Date(millis).toISOString();
}

function cursorQuota(key, label, usedPercent, resetsAt) {
  const used = clampPercent(usedPercent);
  if (used == null) return null;
  return {
    key,
    label,
    usedPercent: used,
    remainingPercent: Math.max(0, 100 - used),
    resetsAt: resetsAt || null,
    expired: false,
  };
}

// xAI Premium (and the other X plans) report one weekly included pool.
// Older Cursor plans report two monthly pools: Cursor's own models and API
// models. `totalPercentUsed` is percent used, matching the dashboard copy.
function cursorUsageFromBodies(planBody, periodBody) {
  const plan = (planBody && planBody.planInfo) || {};
  const period = periodBody || {};
  const usage = period.planUsage || {};
  const weekly =
    plan.includedUsagePeriod === 'INCLUDED_USAGE_PERIOD_WEEKLY' ||
    plan.includedUsagePeriod === 2;
  const weeklyReset =
    cursorEpochIso(plan.includedUsageResetsAt) ||
    cursorEpochIso(period.billingCycleEnd);
  const cycleEnd = cursorEpochIso(period.billingCycleEnd);
  let quotas;
  if (weekly) {
    quotas = [
      cursorQuota('seven_day', 'Weekly quota', usage.totalPercentUsed, weeklyReset),
    ];
  } else {
    quotas = [
      cursorQuota('cursor_models', 'Cursor models', usage.autoPercentUsed, cycleEnd),
      cursorQuota('api_models', 'API models', usage.apiPercentUsed, cycleEnd),
    ];
    if (!quotas.some(Boolean) && usage.totalPercentUsed != null) {
      quotas = [
        cursorQuota('seven_day', 'Weekly quota', usage.totalPercentUsed, cycleEnd),
      ];
    }
  }
  return {
    plan: plan.planName || 'Cursor',
    quotas: quotas.filter(Boolean),
  };
}

async function readCursorAccessToken() {
  let auth;
  try {
    auth = JSON.parse(fs.readFileSync(cursorAuthFile(), 'utf8'));
  } catch (_err) {
    auth = {};
  }
  if (typeof auth.accessToken === 'string' && auth.accessToken) {
    return auth.accessToken;
  }
  const apiKey = process.env.CURSOR_API_KEY;
  if (!apiKey) {
    throw new Error('Cursor credentials were not found. Run agent login.');
  }
  const exchanged = await httpJson(
    'POST',
    CURSOR_EXCHANGE_URL,
    { Authorization: `Bearer ${apiKey}` },
    {},
  );
  if (exchanged.status !== 200 || !exchanged.body || !exchanged.body.accessToken) {
    throw new UsageQueryError(
      `Cursor API key was rejected (HTTP ${exchanged.status}). Run agent login again.`,
      exchanged.status,
    );
  }
  return exchanged.body.accessToken;
}

async function fetchCursorUsage() {
  const token = await readCursorAccessToken();
  const headers = {
    Authorization: `Bearer ${token}`,
    'Connect-Protocol-Version': '1',
    Accept: 'application/json',
  };
  const [plan, period] = await Promise.all([
    httpJson('POST', CURSOR_PLAN_URL, headers, {}),
    httpJson('POST', CURSOR_PERIOD_URL, headers, {}),
  ]);
  if (plan.status === 401 || period.status === 401) {
    throw new UsageQueryError(
      'Cursor credentials were rejected. Run agent login again.',
      401,
    );
  }
  if (period.status !== 200 || !period.body) {
    throw new UsageQueryError(
      `Cursor usage query failed (HTTP ${period.status}).`,
      period.status,
    );
  }
  return cursorUsageFromBodies(plan.status === 200 ? plan.body : {}, period.body);
}

async function getCursorUsage() {
  return cachedUsage({
    key: 'cursor',
    ttlMs: 60_000,
    getMemoryCache: () => cursorCache,
    setMemoryCache: (cache) => {
      cursorCache = cache;
    },
    fetcher: fetchCursorUsage,
  });
}

// Agents whose quota we can report. `normalize` maps each fetcher's own result
// shape onto a common { detail, asOf, stale, fiveHour, sevenDay } or a ready
// `quotas` list, so the agent payload is built once below.
// Preserve every quota pool: Argon can have a separate limit from other Gemini models.
function agyUsageFromBody(body) {
  const response =
    body &&
    ((body.command && body.command.data) ||
      (body.response && typeof body.response === 'object'
        ? body.response
        : null) ||
      body);
  const quotas = [];
  for (const group of Array.isArray(response && response.groups) ? response.groups : []) {
    const groupName =
      group.displayName || group.display_name || group.name || 'Antigravity';
    // "Claude and GPT models" → "Claude/GPT"; the app adds the localized window.
    const model = String(groupName).replace(/\s+models$/i, '').replace(/ and /gi, '/').slice(0, 80);
    const items = [];
    for (const bucket of Array.isArray(group.buckets) ? group.buckets : []) {
      const fraction = bucket.remainingFraction ?? bucket.remaining_fraction;
      if (typeof fraction !== 'number' || !Number.isFinite(fraction)) continue;
      const reset = Date.parse(bucket.resetTime || bucket.reset_time);
      const bucketId =
        bucket.bucketId || bucket.bucket_id || bucket.id || `agy-${quotas.length + items.length}`;
      const windowMatch = /(5h|weekly)$/.exec(String(bucket.window || bucketId));
      const window = windowMatch ? windowMatch[1] : null;
      const bucketName =
        bucket.displayName ||
        bucket.display_name ||
        bucket.name ||
        bucket.window ||
        bucketId;
      items.push({
        key: String(bucketId),
        label: window ? model : `${model} · ${String(bucketName).slice(0, 80)}`,
        window,
        usedPercent: clampPercent((1 - fraction) * 100),
        remainingPercent: clampPercent(fraction * 100),
        resetsAt: Number.isFinite(reset) ? new Date(reset).toISOString() : null,
        expired: false,
      });
    }
    // 5 hours before the week, as Claude and Codex read.
    const rank = (item) => (item.window === '5h' ? 0 : item.window === 'weekly' ? 1 : 2);
    quotas.push(...items.sort((a, b) => rank(a) - rank(b)));
  }
  if (!quotas.length) throw new UsageQueryError('Antigravity returned no quota buckets.', 503);
  return { quotas };
}

function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err.code === 'EPERM';
  }
}

// Live ACP workers (pid in the file name) always count: `agy models` and each
// /usage fallback add a cli log, which would otherwise push a running worker out.
function agyQuotaLogNames(names, isAlive = pidAlive) {
  const newest = (list) =>
    list.sort((a, b) => b.replace(/^[a-z-]+/, '').localeCompare(a.replace(/^[a-z-]+/, '')));
  const workers = names.filter((name) => {
    const match = /^acp-worker-\d{8}_\d{6}-(\d+)\.log$/.exec(name);
    return match && isAlive(Number(match[1]));
  });
  const clis = names.filter((name) => /^cli-\d{8}_\d{6}(?:-\d+)?\.log$/.test(name));
  return [...newest(workers), ...newest(clis).slice(0, 12)];
}

function readAgyPorts() {
  const dir = path.join(path.dirname(agyAuthFile()), 'log');
  let files = [];
  try {
    files = agyQuotaLogNames(fs.readdirSync(dir));
  } catch (_err) { /* No CLI has run on this host yet. */ }
  const tried = new Set();
  for (const name of files) {
    let text;
    try {
      const fd = fs.openSync(path.join(dir, name), 'r');
      try {
        // The port is logged at startup; a long conversation grows the log far past it.
        const bytes = Buffer.alloc(65536);
        text = bytes.toString('utf8', 0, fs.readSync(fd, bytes, 0, bytes.length, 0));
      } finally { fs.closeSync(fd); }
    } catch (_err) { continue; }
    const match = /Language server listening on random port at (\d+) for HTTP\b/.exec(text);
    const port = match && Number(match[1]);
    if (port >= 1 && port <= 65535) tried.add(port);
  }
  return [...tried];
}

function callAgyLanguageServer(port, method, body = {}, timeoutMs = 1000) {
  return httpJson(
    'POST',
    `http://127.0.0.1:${port}/exa.language_server_pb.LanguageServerService/${method}`,
    { Accept: 'application/json' },
    body,
    timeoutMs,
  );
}

function runAgyUsageCommand(bin = locateBin('agy')) {
  return new Promise((resolve, reject) => {
    if (!bin) {
      reject(new UsageQueryError('Antigravity CLI is not installed on this host.', 503));
      return;
    }
    execFile(
      bin,
      ['-p', '/usage', '--output-format', 'json'],
      { timeout: 20000, maxBuffer: 1024 * 1024 },
      (err, stdout) => {
        const text = String(stdout || '').trim();
        if (!text && err) {
          reject(err);
          return;
        }
        try {
          resolve(JSON.parse(text));
          return;
        } catch (_err) {
          const lines = text.split(/\r?\n/).reverse();
          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed.startsWith('{')) continue;
            try {
              resolve(JSON.parse(trimmed));
              return;
            } catch (_lineErr) { /* Keep scanning. */ }
          }
          reject(err || new UsageQueryError('Antigravity usage output was not valid JSON.', 503));
        }
      },
    );
  });
}

async function fetchAgyUsage(options = {}) {
  const ports =
    options.ports || (options.readPorts ? options.readPorts() : readAgyPorts());
  const callRpc =
    options.callRpc || options.callServer || callAgyLanguageServer;
  for (const port of ports) {
    try {
      const result = await callRpc(
        port,
        'RetrieveUserQuotaSummary',
        {},
        1000,
      );
      const body =
        result && result.status === 200
          ? result.body
          : result && (result.response || result.groups)
            ? result
            : null;
      if (body) return agyUsageFromBody(body);
    } catch (_err) { /* A stopped CLI leaves a stale port in its log. */ }
  }
  const runCli = options.runCli || runAgyUsageCommand;
  try {
    return agyUsageFromBody(await runCli());
  } catch (err) {
    if (err instanceof UsageQueryError) throw err;
    throw new UsageQueryError(
      'Antigravity quota query failed. Check that agy is logged in on this host.',
      503,
    );
  }
}

function agyContextFromTrajectory(body) {
  const gm = body && body.trajectory && body.trajectory.generatorMetadata;
  if (!Array.isArray(gm) || !gm.length) return null;
  for (let i = gm.length - 1; i >= 0; i -= 1) {
    const chatModel = gm[i] && gm[i].chatModel;
    const meta =
      chatModel &&
      chatModel.chatStartMetadata &&
      chatModel.chatStartMetadata.contextWindowMetadata;
    if (!meta) continue;
    const used = Number(
      meta.estimatedTokensUsed ??
        (meta.tokenBreakdown && meta.tokenBreakdown.totalTokens),
    );
    const size = Number(meta.maxContextTokens);
    if (Number.isFinite(used) && used >= 0 && Number.isFinite(size) && size > 0) {
      return {
        used: Math.round(used),
        size: Math.round(size),
        steps: gm.length,
        model: chatModel.model || null,
      };
    }
  }
  return null;
}

const AGY_SESSION_UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function readAgyContext(sessionId, options = {}) {
  const id = String(sessionId || '').trim();
  if (!AGY_SESSION_UUID_RE.test(id)) return null;
  const ports =
    options.ports || (options.readPorts ? options.readPorts() : readAgyPorts());
  const callRpc =
    options.callRpc || options.callServer || callAgyLanguageServer;
  // Read-only on every candidate at once: the worker that just ran the turn holds
  // it in memory, so no LoadTrajectory into another process is needed.
  const found = await Promise.all(ports.map(async (port) => {
    try {
      const result = await callRpc(port, 'GetCascadeTrajectory', { cascadeId: id }, 1500);
      const body =
        result && result.status === 200
          ? result.body
          : result && result.trajectory
            ? result
            : null;
      return body ? agyContextFromTrajectory(body) : null;
    } catch (_err) {
      return null; // A stopped CLI leaves a stale port in its log.
    }
  }));
  let best = null;
  for (const ctx of found) {
    if (ctx && (!best || ctx.steps > best.steps)) best = ctx;
  }
  return best ? { used: best.used, size: best.size } : null;
}

function getAgyUsage() {
  // Longer than the composer strip's one-minute poll, so a poll is not a cold `agy -p /usage`.
  return cachedUsage({ key: 'agy', ttlMs: 5 * 60 * 1000,
    getMemoryCache: () => agyCache,
    setMemoryCache: (cache) => { agyCache = cache; },
    fetcher: fetchAgyUsage });
}

const USAGE_SOURCES = [
  {
    key: 'claude',
    label: 'Claude Code',
    fetch: getClaudeUsage,
    normalize: (r) => ({
      detail: r.subscriptionType || '',
      asOf: r.fetchedAt || null,
      stale: !!r.stale,
      fiveHour: r.data.five_hour,
      sevenDay: r.data.seven_day,
    }),
  },
  {
    key: 'codex',
    label: 'Codex',
    fetch: getCodexUsage,
    normalize: (r) => ({
      detail: r.plan || '',
      asOf: r.fetchedAt || null,
      stale: !!r.stale,
      fiveHour: r.five_hour,
      sevenDay: r.seven_day,
    }),
  },
  {
    key: 'cursor',
    label: 'Cursor',
    fetch: getCursorUsage,
    normalize: (r) => ({
      detail: r.plan || '',
      asOf: r.fetchedAt || null,
      stale: !!r.stale,
      quotas: Array.isArray(r.quotas) ? r.quotas : [],
    }),
  },
  { key: 'agy', label: 'Antigravity', fetch: getAgyUsage,
    normalize: (r) => ({ detail: '', asOf: r.fetchedAt || null, stale: !!r.stale, quotas: r.quotas }) },
];

async function buildAgentUsage({ key, label, fetch, normalize, unavailable }) {
  if (unavailable) {
    return { key, label, available: false, unavailableReason: unavailable, quotas: [] };
  }
  try {
    const normalized = normalize(await fetch());
    const { detail, asOf, stale, fiveHour, sevenDay } = normalized;
    const quotas = Array.isArray(normalized.quotas)
      ? normalized.quotas
      : [
          quotaItem('five_hour', '5 hour quota', fiveHour),
          quotaItem('seven_day', 'Weekly quota', sevenDay),
        ];
    return {
      key,
      label,
      available: true,
      detail,
      asOf,
      stale,
      quotas: markExpiredQuotas(quotas, stale),
    };
  } catch (err) {
    return { key, label, available: true, error: err.message, quotas: [] };
  }
}

// `source` limits the report to one agent so the app can query each separately
// and show whichever answers first instead of waiting for the slowest.
async function buildUsageReport({ source } = {}) {
  const sources = source
    ? USAGE_SOURCES.filter((item) => item.key === source)
    : USAGE_SOURCES;
  if (sources.length === 0) {
    throw new UsageQueryError(`Unknown usage source: ${source}`, 400);
  }
  // The fetched sources are independent network round-trips; run them together so
  // the dialog waits for the slower one, not the sum of all of them.
  const agents = await Promise.all(sources.map(buildAgentUsage));

  return {
    createdAt: new Date().toISOString(),
    mode: 'remaining',
    hasStale: agents.some((agent) => agent.stale === true),
    agents,
  };
}

module.exports = {
  agyContextFromTrajectory,
  agyUsageFromBody,
  agyQuotaLogNames,
  fetchAgyUsage,
  readAgyContext,
  getClaudeUsage,
  getCodexUsage,
  cursorUsageFromBodies,
  invalidateUsageCache,
  markExpiredQuotas,
  primeClaudeSession,
  buildUsageReport,
};
