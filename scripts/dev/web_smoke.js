#!/usr/bin/env node
// Smoke test of the Relay Web client against the live backend.
//
//   node scripts/dev/web_smoke.js
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {
  BASE_URL,
  DRAWER,
  PREFIX,
  SHOTS,
  VIEWPORTS,
  WEB_BUILD_HINT,
  api,
  cleanupTestData,
  createTestToken,
  deleteTestToken,
  escapeRegex,
  loadPlaywright,
  openRelayPage,
  runSteps,
} = require('./lib/relay_web');

const REPO = path.resolve(__dirname, '../..');
const WEB_INDEX = path.join(REPO, 'app', 'shell', 'build', 'web', 'index.html');
const REPLY_TIMEOUT_MS = 180_000;

async function preflight() {
  if (!fs.existsSync(WEB_INDEX)) {
    console.error(`build the Web client first: ${WEB_BUILD_HINT}`);
    process.exit(2);
  }
  const healthUrl = new URL('api/health', BASE_URL.endsWith('/') ? BASE_URL : `${BASE_URL}/`).toString();
  try {
    await fetch(healthUrl);
  } catch (_) {
    console.error(`relay-server is not reachable at ${BASE_URL}`);
    process.exit(2);
  }
  fs.mkdirSync(SHOTS, { recursive: true });
}

async function setupSession(token) {
  const created = await api(token, 'POST', '/api/sessions', {
    agent: 'claude',
    name: `${PREFIX} smoke`,
  });
  const sessionId = created.sessionId || created.session?.id || created.activeSessionId;
  if (!sessionId) throw new Error('POST /api/sessions did not return a sessionId');
  await api(token, 'POST', '/api/sessions/active', { agent: 'claude', sessionId });
  const options = await api(token, 'GET', '/api/agent-options?agent=claude');
  const models = Array.isArray(options?.model) ? options.model : [];
  const cheapest = models.find((m) => /haiku/i.test(m.id || '') || /haiku/i.test(m.label || ''));
  const model = cheapest?.id || options?.defaults?.model || models[0]?.id;
  if (model) {
    await api(token, 'POST', '/api/agent-settings', { agent: 'claude', sessionId, model });
  }
  return sessionId;
}

async function openDrawerIfMobile(page, isMobile) {
  if (!isMobile) return;
  const menu = page.getByRole('button', { name: /^Menu$/ });
  if (await menu.isVisible().catch(() => false)) {
    await menu.click();
  } else {
    await page.mouse.click(...DRAWER);
  }
  await page.getByRole('button', { name: /^Settings$/ }).waitFor({ state: 'visible', timeout: 10000 });
}

async function openChat(page, isMobile) {
  await openDrawerIfMobile(page, isMobile);
  const claude = page.getByRole('button', { name: /Claude Code/ }).first();
  if (await claude.isVisible().catch(() => false)) {
    await claude.click();
  } else {
    await page.getByText('Claude Code', { exact: true }).first().click();
  }
  await page.getByRole('textbox').first().waitFor({ state: 'visible', timeout: 15000 });
  await page.waitForTimeout(1000);
}

async function openDrawerRoute(page, isMobile, label, waitForLocator) {
  await openDrawerIfMobile(page, isMobile);
  await runSteps(page, [{ button: label, wait: 1000 }]);
  await waitForLocator.waitFor({ state: 'visible', timeout: 20000 });
  await page.waitForTimeout(1000);
}

async function goBack(page) {
  const back = page.getByRole('button', { name: /^Back$/ }).first();
  await back.waitFor({ state: 'visible', timeout: 10000 });
  await back.click();
  await page.waitForTimeout(1000);
}

async function waitForReply(token, sessionId) {
  const deadline = Date.now() + REPLY_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const history = await api(token, 'GET', `/api/history?agent=claude&sessionId=${encodeURIComponent(sessionId)}`);
    const messages = Array.isArray(history?.messages) ? history.messages : [];
    const settled = messages.find((msg) => msg.role === 'assistant' && !msg.metadata?.streaming);
    if (settled) {
      if (settled.metadata?.errorCode || settled.metadata?.error) {
        throw new Error(`assistant returned error: ${settled.metadata.errorCode || settled.metadata.error}`);
      }
      if (String(settled.content || '').includes('OK')) return settled;
      throw new Error(`assistant reply did not contain OK: ${JSON.stringify(String(settled.content || '').slice(0, 120))}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error(`timed out after ${REPLY_TIMEOUT_MS / 1000}s waiting for assistant reply`);
}

async function main() {
  await preflight();

  const results = [];
  const allErrors = [];
  let tokenRecord = null;
  let browser = null;
  let cleaned = false;

  const cleanup = async () => {
    if (cleaned) return;
    cleaned = true;
    if (browser) {
      await browser.close().catch(() => {});
      browser = null;
    }
    if (tokenRecord) {
      try {
        await cleanupTestData(tokenRecord.token);
      } catch (err) {
        console.error(`cleanup warning: ${err.message}`);
      }
      deleteTestToken(tokenRecord);
      tokenRecord = null;
    }
  };

  const onSignal = (signal) => {
    cleanup().finally(() => process.exit(signal === 'SIGINT' ? 130 : 143));
  };
  process.once('SIGINT', onSignal);
  process.once('SIGTERM', onSignal);

  const runCheck = async (name, shotName, page, errors, fn) => {
    const shotPath = shotName ? path.join(SHOTS, shotName) : '-';
    const startErrs = errors ? errors.length : 0;
    try {
      await fn();
      if (page && shotName) await page.screenshot({ path: shotPath });
      const newErrs = errors ? errors.slice(startErrs) : [];
      results.push({ ok: newErrs.length === 0, name, shotPath, error: newErrs[0] || '' });
    } catch (err) {
      if (page && shotName) await page.screenshot({ path: shotPath }).catch(() => {});
      results.push({ ok: false, name, shotPath, error: err.message || String(err) });
    }
  };

  try {
    tokenRecord = createTestToken();
    const { token } = tokenRecord;
    const health = await api(token, 'GET', '/api/health');
    if (!health?.ok) throw new Error('authenticated /api/health did not return ok');

    await cleanupTestData(token);
    const sessionId = await setupSession(token);

    const { chromium } = loadPlaywright();
    browser = await chromium.launch();

    for (const [viewportName, size] of Object.entries(VIEWPORTS)) {
      const isMobile = viewportName === 'mobile';
      const { page, errors } = await openRelayPage(browser, { token, viewport: size });
      try {
        await runCheck(`${viewportName}-home`, `${viewportName}-home.png`, page, errors, async () => {
          await page.getByText('Relay Web Test').first().waitFor({ state: 'visible', timeout: 15000 });
          await page.waitForTimeout(1000);
        });

        await runCheck(`${viewportName}-chat`, `${viewportName}-chat.png`, page, errors, async () => {
          await openChat(page, isMobile);
          // The header names the open session; the smoke session must be the one shown.
          await page.getByText(new RegExp(escapeRegex(`Claude Code - ${PREFIX} smoke`))).first()
            .waitFor({ state: 'visible', timeout: 15000 });
        });

        if (viewportName === 'desktop') {
          await runCheck('desktop-chat-reply', 'desktop-chat-reply.png', page, errors, async () => {
            const box = page.getByRole('textbox').first();
            await box.click();
            await box.fill('Reply with exactly: OK');
            await box.press('Enter');
            await waitForReply(token, sessionId);
            await page.waitForTimeout(1500);
          });
        }

        await runCheck(`${viewportName}-files`, `${viewportName}-files.png`, page, errors, async () => {
          await openDrawerRoute(page, isMobile, 'File system', page.getByRole('button', { name: /^Back$/ }).first());
        });
        await goBack(page).catch(() => {});

        await runCheck(`${viewportName}-browser`, `${viewportName}-browser.png`, page, errors, async () => {
          await openDrawerRoute(page, isMobile, 'Browser', page.getByRole('textbox').first());
        });
        await goBack(page).catch(() => {});

        await runCheck(`${viewportName}-settings`, `${viewportName}-settings.png`, page, errors, async () => {
          await openDrawerRoute(page, isMobile, 'Settings', page.getByRole('button', { name: /^Back$/ }).first());
        });
        await goBack(page).catch(() => {});
      } finally {
        for (const err of errors) allErrors.push(`${viewportName}: ${err}`);
        await page.close();
      }
    }
  } finally {
    process.removeListener('SIGINT', onSignal);
    process.removeListener('SIGTERM', onSignal);
    await cleanup();
  }

  for (const r of results) {
    const status = r.ok ? 'PASS' : 'FAIL';
    const suffix = r.error ? ` ${r.error}` : '';
    console.log(`${status} ${r.name} ${r.shotPath}${suffix}`);
  }
  for (const err of allErrors) {
    console.log(`ERROR ${err}`);
  }
  const passed = results.filter((r) => r.ok).length;
  const failed = results.length - passed;
  console.log(`Summary: ${passed} passed, ${failed} failed, ${allErrors.length} unexpected errors`);
  process.exit(failed > 0 || allErrors.length > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
