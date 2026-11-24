'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const PLAYWRIGHT_VERSION = '1.63.0';
const BASE_URL = process.env.RELAY_TEST_URL || 'http://127.0.0.1:8787';
// The only workdir test sessions may use; the rest of ~/playground is the user's.
const ROOT = path.join(os.homedir(), 'playground', 'relay-web-test');
const SHOTS = path.join(ROOT, 'shots');
const LABEL = 'relay-web-test';
const PREFIX = '[web-test]';
const DRAWER = [28, 27];
const VIEWPORTS = {
  desktop: [1440, 960, 1],
  mobile: [400, 820, 2],
};
const WEB_BUILD_HINT =
  '(cd app/shell && flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn)';

// Known benign browser errors (each entry: { pattern: RegExp, reason: string }).
const EXPECTED = [];

function loadPlaywright() {
  if (process.env.PLAYWRIGHT_CORE) return require(process.env.PLAYWRIGHT_CORE);
  const dir = path.join(os.tmpdir(), `relay-playwright-${PLAYWRIGHT_VERSION}`);
  const mod = path.join(dir, 'node_modules', 'playwright-core');
  if (!fs.existsSync(mod)) {
    execFileSync('npm', ['install', '--prefix', dir, '--no-save', `playwright-core@${PLAYWRIGHT_VERSION}`], {
      stdio: 'inherit',
    });
  }
  // A no-op when the matching browser is already in the Playwright cache.
  execFileSync(process.execPath, [path.join(mod, 'cli.js'), 'install', 'chromium'], { stdio: 'inherit' });
  return require(mod);
}

async function seedStorage(page, {
  machineId,
  name,
  baseUrl,
  token,
  machines,
  activeMachineId,
  deviceId,
  prefs = {},
}) {
  const list = Array.isArray(machines) && machines.length > 0
    ? machines.map((m) => ({
      id: m.id,
      name: m.name,
      baseUrl: m.baseUrl,
      token: m.token,
      createdAt: m.createdAt || '2026-01-01T00:00:00.000Z',
    }))
    : [{
      id: machineId,
      name,
      baseUrl,
      token,
      createdAt: '2026-01-01T00:00:00.000Z',
    }];
  const activeId = activeMachineId || list[0].id;
  await page.evaluate(async ({ list: items, activeId: active, deviceId: devId, prefs: extra }) => {
    localStorage.clear();
    const pref = (key, value) => localStorage.setItem(`flutter.${key}`, JSON.stringify(value));
    const b64 = (buffer) => {
      let text = '';
      for (const byte of new Uint8Array(buffer)) text += String.fromCharCode(byte);
      return btoa(text);
    };

    pref('relay.active_machine_id.v1', active);
    for (const [key, value] of Object.entries(extra)) pref(key, value);

    // flutter_secure_storage_web 1.x keeps a raw AES-GCM key under its public
    // key and each value as "<iv>.<ciphertext>", both base64.
    const key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']);
    localStorage.setItem('FlutterSecureStorage', b64(await crypto.subtle.exportKey('raw', key)));
    const seal = async (value) => {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const sealed = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, new TextEncoder().encode(value));
      return `${b64(iv)}.${b64(sealed)}`;
    };
    localStorage.setItem('FlutterSecureStorage.relay.machine_credentials.v1', await seal(JSON.stringify(items)));
    if (devId) {
      localStorage.setItem('FlutterSecureStorage.relay.device_id.v1', await seal(devId));
    }
  }, { list, activeId, deviceId, prefs });
}

function escapeRegex(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function enableSemantics(page) {
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'attached', timeout: 30000 });
  // Flutter paints to canvas; enable its semantics tree to target labels.
  await placeholder.evaluate((element) => element.click());
  await page.waitForTimeout(500);
  // Mobile touch contexts ignore synthetic click on the placeholder; tap instead.
  if ((await page.locator('flt-semantics').count()) === 0) {
    await placeholder.tap({ force: true }).catch(() => {});
    await page.waitForTimeout(500);
  }
}

async function runSteps(page, steps, { lang = 'en' } = {}) {
  for (const step of steps) {
    if (step.tap) {
      await page.mouse.click(...step.tap);
    } else if (step.button) {
      const label = Array.isArray(step.button) ? step.button[lang === 'zh' ? 1 : 0] : step.button;
      await page.getByRole('button', { name: new RegExp(escapeRegex(label)) }).click();
    } else if (step.scroll) {
      await page.mouse.move(step.scroll[0], step.scroll[1]);
      await page.mouse.wheel(0, step.scroll[2]);
    }
    await page.waitForTimeout(step.wait ?? (step.scroll ? 1000 : 3000));
  }
}

function tokensApi() {
  return require('../../../server/lib/tokens');
}

function createTestToken() {
  const tokens = tokensApi();
  for (const summary of tokens.listTokenSummaries()) {
    if (summary.label !== LABEL) continue;
    if (!summary.revoked) tokens.revokeTokenById(summary.id);
    tokens.deleteRevokedTokenById(summary.id);
  }
  return tokens.createToken({ label: LABEL });
}

function deleteTestToken(record) {
  if (!record || !record.id) return;
  const tokens = tokensApi();
  tokens.revokeTokenById(record.id);
  tokens.deleteRevokedTokenById(record.id);
}

async function api(token, method, apiPath, body, { baseUrl = BASE_URL, workdir = ROOT, deviceId = LABEL } = {}) {
  const base = baseUrl.endsWith('/') ? baseUrl : `${baseUrl}/`;
  const cleanPath = apiPath.startsWith('/') ? apiPath.slice(1) : apiPath;
  const url = new URL(cleanPath, base).toString();
  const headers = {
    Accept: 'application/json',
    'Content-Type': 'application/json',
    Authorization: `Bearer ${String(token).trim()}`,
    'X-Device-Id': deviceId,
    'X-Device-Name': 'Relay Web Test',
    'X-Workdir': encodeURI(workdir),
  };
  const res = await fetch(url, {
    method,
    headers,
    body: method === 'GET' ? undefined : JSON.stringify(body ?? {}),
  });
  const text = await res.text();
  let parsed = null;
  if (text.trim()) {
    try {
      parsed = JSON.parse(text);
    } catch (_) {
      parsed = text;
    }
  }
  if (!res.ok) {
    const detail = parsed && typeof parsed === 'object' && parsed.error ? parsed.error : text.trim() || `HTTP ${res.status}`;
    const err = new Error(`${method} ${apiPath} failed (${res.status}): ${detail}`);
    err.status = res.status;
    err.body = parsed;
    throw err;
  }
  return parsed;
}

async function cleanupTestData(token, workdirs = [ROOT], { baseUrl = BASE_URL, agents = ['claude'] } = {}) {
  const dirs = Array.isArray(workdirs) ? workdirs : [workdirs];
  for (const workdir of dirs) {
    for (const agent of agents) {
      const sessionsRes = await api(
        token,
        'GET',
        `/api/sessions?agent=${encodeURIComponent(agent)}`,
        undefined,
        { baseUrl, workdir },
      );
      for (const session of sessionsRes?.sessions || []) {
        if (session.id === 'default' || !String(session.name || '').startsWith(PREFIX)) continue;
        await api(
          token,
          'POST',
          '/api/sessions/delete',
          { agent, sessionId: session.id },
          { baseUrl, workdir },
        );
      }
    }
  }
  const groupsRes = await api(token, 'GET', '/api/groups', undefined, { baseUrl });
  for (const group of groupsRes?.groups || []) {
    if (!String(group.name || '').startsWith(PREFIX)) continue;
    await api(token, 'POST', '/api/groups/delete', { groupId: group.id }, { baseUrl });
  }
}

function isExpectedError(entry) {
  return EXPECTED.some(({ pattern }) => pattern.test(entry));
}

async function openRelayPage(browser, {
  token,
  machines,
  activeMachineId,
  deviceId,
  viewport = VIEWPORTS.desktop,
  prefs = {},
  allow = null,
  contextOptions = {},
}) {
  const [width, height, dpr] = Array.isArray(viewport) ? viewport : VIEWPORTS[viewport];
  const page = await browser.newPage({
    viewport: { width, height },
    deviceScaleFactor: dpr,
    locale: 'en-US',
    ...contextOptions,
  });
  const machineList = Array.isArray(machines) && machines.length > 0
    ? machines
    : [{ id: LABEL, name: 'Relay Web Test', baseUrl: BASE_URL, token }];
  const activeId = activeMachineId || machineList[0].id;
  const workdirPrefs = {};
  for (const m of machineList) {
    if (m.workdir) workdirPrefs[`relay.workdir.v2.${m.id}`] = m.workdir;
  }
  if (!workdirPrefs[`relay.workdir.v2.${activeId}`]) {
    workdirPrefs[`relay.workdir.v2.${activeId}`] = ROOT;
  }

  const base = BASE_URL.endsWith('/') ? BASE_URL : `${BASE_URL}/`;
  // Load a tiny static file on the same origin to seed localStorage before Flutter boots.
  await page.goto(new URL('manifest.json', base).toString(), { waitUntil: 'domcontentloaded' });
  await seedStorage(page, {
    machines: machineList,
    activeMachineId: activeId,
    deviceId,
    prefs: {
      'relay.language.v1': 'en',
      ...workdirPrefs,
      'relay.active_cli_agent.v1': 'claude',
      ...prefs,
    },
  });

  const errors = [];
  let allowRule = allow;
  const isAllowed = (entry) => {
    if (isExpectedError(entry)) return true;
    if (!allowRule) return false;
    return allowRule instanceof RegExp ? allowRule.test(entry) : Boolean(allowRule(entry));
  };
  const record = (entry) => {
    if (!isAllowed(entry)) errors.push(entry);
  };
  const setAllow = (rule) => {
    allowRule = rule || null;
  };
  page.on('console', (msg) => {
    if (msg.type() === 'error') record(`console: ${msg.text()}`);
  });
  page.on('pageerror', (err) => {
    record(`pageerror: ${err.message || String(err)}`);
  });
  page.on('requestfailed', (req) => {
    record(`requestfailed: ${req.method()} ${req.url()} (${req.failure()?.errorText || 'failed'})`);
  });
  page.on('response', (res) => {
    if (res.status() >= 400) record(`http ${res.status()}: ${res.request().method()} ${res.url()}`);
  });

  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded' });
  await enableSemantics(page);
  // Wait for the home screen to render rather than using a blind long sleep.
  await page.getByRole('button', { name: /Browse all articles|Menu|Home/ }).first().waitFor({ timeout: 30000 });
  return { page, errors, setAllow };
}

module.exports = {
  BASE_URL,
  DRAWER,
  EXPECTED,
  LABEL,
  PREFIX,
  ROOT,
  SHOTS,
  VIEWPORTS,
  WEB_BUILD_HINT,
  api,
  cleanupTestData,
  createTestToken,
  deleteTestToken,
  enableSemantics,
  escapeRegex,
  loadPlaywright,
  openRelayPage,
  runSteps,
  seedStorage,
};
