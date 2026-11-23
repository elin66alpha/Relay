#!/usr/bin/env node
// Real-browser test of multi-machine Swarms and machine switching.
//
//   node scripts/dev/web_swarm.js
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync, spawn } = require('node:child_process');
const {
  BASE_URL,
  DRAWER,
  PREFIX,
  ROOT,
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
} = require('./lib/relay_web');

const REPO = path.resolve(__dirname, '../..');
const WEB_INDEX = path.join(REPO, 'app', 'shell', 'build', 'web', 'index.html');
const PEER_PORT = Number(process.env.RELAY_PEER_PORT || 8797);
const PEER_URL = `http://127.0.0.1:${PEER_PORT}`;
const PEER_DIR = path.join(ROOT, 'peer');
const PEER_SERVER = path.join(PEER_DIR, 'server');
const SWARM_HOST_DIR = path.join(ROOT, 'swarm-host');
const SWARM_PEER_DIR = path.join(ROOT, 'swarm-peer');
const HOST_ID = 'relay-web-test-host';
const PEER_ID_MACHINE = 'relay-web-test-peer';
const HOST_NAME = 'Relay Web Test';
const PEER_NAME = 'Relay Peer Test';
const SWARM_NAME = `${PREFIX} swarm`;
const PEER_HASH = crypto.createHash('sha256').update(PEER_URL).digest('hex').slice(0, 12);
const REMOTE_KEY = `${PEER_HASH}:claude`;
const ROUND_TIMEOUT_MS = 240_000;

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

async function startPeerServer(peerToken) {
  fs.rmSync(PEER_DIR, { recursive: true, force: true });
  fs.mkdirSync(SWARM_HOST_DIR, { recursive: true });
  fs.mkdirSync(SWARM_PEER_DIR, { recursive: true });

  // Tracked server files only so the peer never touches live deployment state.
  const tracked = execFileSync('git', ['ls-files', 'server'], { cwd: REPO }).toString().trim().split('\n');
  for (const rel of tracked) {
    const dest = path.join(PEER_DIR, rel);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(path.join(REPO, rel), dest);
  }
  fs.symlinkSync(path.join(REPO, 'server', 'node_modules'), path.join(PEER_SERVER, 'node_modules'));
  fs.writeFileSync(
    path.join(PEER_SERVER, 'tokens.json'),
    JSON.stringify([{
      id: 'peer-test',
      token: peerToken,
      label: PEER_NAME,
      createdAt: new Date().toISOString(),
      revoked: false,
    }], null, 2),
  );

  // Strip deployment overrides so the peer binds strictly to its test port and dirs.
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
    !/^(PORT|HOST|PUBLIC_BASE_URL|RELAY_.*|ENABLE_.*)$/.test(key)));
  const logFd = fs.openSync(path.join(PEER_DIR, 'peer.log'), 'a');
  const child = spawn(process.execPath, ['server.js'], {
    cwd: PEER_SERVER,
    stdio: ['ignore', logFd, logFd],
    env: {
      ...env,
      PORT: String(PEER_PORT),
      HOST: '127.0.0.1',
      RELAY_DEFAULT_DIR: SWARM_PEER_DIR,
      RELAY_FS_ROOTS: ROOT,
      ENABLE_QUOTA_WATCH: 'false',
      ENABLE_CLAUDE_KEEPALIVE: 'false',
    },
  });
  fs.closeSync(logFd);

  for (let i = 0; i < 30; i += 1) {
    if (child.exitCode !== null) throw new Error(`peer server exited (${child.exitCode}); check ${PEER_DIR}/peer.log`);
    try {
      const health = await api(peerToken, 'GET', '/api/health', undefined, {
        baseUrl: PEER_URL,
        workdir: SWARM_PEER_DIR,
      });
      if (health?.ok) return child;
    } catch (_) {
      // Not listening yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  child.kill();
  throw new Error(`peer server did not answer on ${PEER_URL}`);
}

async function stopChild(child) {
  if (!child || child.exitCode !== null) return;
  child.kill('SIGTERM');
  await new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (child.exitCode === null) child.kill('SIGKILL');
      resolve();
    }, 5000);
    child.once('exit', () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

async function getClaudeModels(token, baseUrl, workdir) {
  const options = await api(token, 'GET', '/api/agent-options?agent=claude', undefined, { baseUrl, workdir });
  const models = Array.isArray(options?.model) ? options.model : [];
  const haiku = models.find((m) => /haiku/i.test(m.id || '') || /haiku/i.test(m.label || ''));
  if (!haiku) throw new Error('haiku model not found in /api/agent-options?agent=claude');
  const defaultId = options?.defaults?.model || models[0]?.id;
  const defaultModel = models.find((m) => m.id === defaultId) || models[0];
  return { haiku, defaultModel };
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

async function openSwarmScreen(page) {
  const swarmTile = page.getByRole('button', { name: /^Swarm\b/ }).first();
  await tapLocator(page, swarmTile, 0.5);
  await page.getByRole('button', { name: /^New swarm$/ }).first().waitFor({ state: 'visible', timeout: 15000 });
  await page.waitForTimeout(800);
}

async function selectSwarmIfNeeded(page, name) {
  if (await page.getByText(name, { exact: true }).first().isVisible({ timeout: 3000 }).catch(() => false)) {
    return;
  }
  // AppBar title InkWell opens the swarm switcher bottom sheet.
  await page.mouse.click(140, 28);
  await page.waitForTimeout(400);
  const item = page.getByRole('button', { name: new RegExp(escapeRegex(name)) }).last();
  await tapLocator(page, item, 0.5);
  await page.waitForTimeout(800);
}

async function pickWorkTreeInDialog(page, startDir, targetDir) {
  await page.getByText('Choose work tree', { exact: true }).waitFor({ state: 'visible', timeout: 10000 });
  let cur = path.resolve(startDir);
  const target = path.resolve(targetDir);

  const waitPath = async (expected) => {
    await page.getByText(expected, { exact: true }).waitFor({ state: 'visible', timeout: 10000 });
    await page.waitForTimeout(250);
  };
  await waitPath(cur);

  while (cur !== target && !target.startsWith(`${cur}${path.sep}`)) {
    const parent = path.dirname(cur);
    if (parent === cur) break;
    await tapLocator(page, page.getByRole('button', { name: /Parent folder|\.\./ }).first());
    cur = parent;
    await waitPath(cur);
  }

  const rel = path.relative(cur, target);
  const segments = rel ? rel.split(path.sep) : [];
  for (const seg of segments) {
    const folderRe = new RegExp(`^${escapeRegex(seg)}$`);
    let btn = page.getByRole('button', { name: folderRe }).first();
    for (let attempt = 0; attempt < 30; attempt += 1) {
      const headerBox = await page.getByText(cur, { exact: true }).boundingBox();
      const okBox = await page.getByRole('button', { name: /^OK$/ }).last().boundingBox();
      const minY = headerBox ? headerBox.y + headerBox.height + 6 : 0;
      const maxY = okBox ? okBox.y - 16 : 9999;
      const btnBox = (await btn.isVisible().catch(() => false)) ? await btn.boundingBox() : null;
      // Flutter ListView keeps off-screen cacheExtent items in semantics; only
      // click once the row is inside the dialog's visible list viewport.
      if (btnBox && btnBox.y >= minY && btnBox.y + btnBox.height <= maxY) break;
      if (headerBox) {
        const delta = btnBox && btnBox.y < minY ? -180 : 180;
        await page.mouse.move(headerBox.x + 120, minY + 100);
        await page.mouse.wheel(0, delta);
      }
      await page.waitForTimeout(200);
      btn = page.getByRole('button', { name: folderRe }).first();
    }
    await tapLocator(page, btn);
    cur = path.join(cur, seg);
    await waitPath(cur);
  }

  await tapLocator(page, page.getByRole('button', { name: /^OK$/ }).last(), 0.5);
  await page.getByText('Choose work tree', { exact: true }).waitFor({ state: 'hidden', timeout: 10000 });
}

async function tapLocator(page, locator, xRatio = 0.4) {
  await locator.waitFor({ state: 'visible', timeout: 10000 });
  const box = await locator.boundingBox();
  if (box) {
    // Flutter semantics containers occasionally overlap tiles; clicking the
    // canvas coordinates avoids pointer-interception retries and trailing icons.
    await page.mouse.click(box.x + box.width * xRatio, box.y + box.height / 2);
  } else {
    await locator.click({ force: true });
  }
}

async function fillBox(page, locator, value) {
  await tapLocator(page, locator, 0.5);
  await page.waitForTimeout(150);
  await locator.fill(value);
  await page.waitForTimeout(150);
}

async function clickChip(page, label, { last = false } = {}) {
  const chips = page.getByRole('checkbox', { name: new RegExp(`^${escapeRegex(label)}`) });
  const target = last ? chips.last() : chips.first();
  await tapLocator(page, target, 0.35);
}

async function selectDropdownOption(page, currentLabel, targetLabel) {
  if (currentLabel === targetLabel) return;
  const triggerBtn = page.getByRole('button', { name: new RegExp(escapeRegex(currentLabel)) }).last();
  if (await triggerBtn.isVisible({ timeout: 3000 }).catch(() => false)) {
    await tapLocator(page, triggerBtn, 0.5);
  } else {
    await tapLocator(page, page.getByText(currentLabel, { exact: true }).last(), 0.5);
  }
  await page.waitForTimeout(300);
  const exactRe = new RegExp(`^${escapeRegex(targetLabel)}$`);
  for (const cand of [
    page.getByRole('button', { name: exactRe }).last(),
    page.getByRole('menuitem', { name: exactRe }).last(),
    page.getByText(targetLabel, { exact: true }).last(),
  ]) {
    if (await cand.isVisible({ timeout: 2000 }).catch(() => false)) {
      await tapLocator(page, cand, 0.5);
      await page.waitForTimeout(300);
      return;
    }
  }
  throw new Error(`dropdown option not visible: ${targetLabel}`);
}

async function sendSwarmPrompt(page, text) {
  const box = page.getByRole('textbox').last();
  await tapLocator(page, box, 0.5);
  await page.waitForTimeout(100);
  await box.fill(text);
  await page.waitForTimeout(100);
  await box.press('Enter');
}

async function waitForGroupRound(token, groupId, prevCount, checkFn) {
  const deadline = Date.now() + ROUND_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const history = await api(token, 'GET', `/api/group/history?groupId=${encodeURIComponent(groupId)}`);
    const messages = Array.isArray(history?.messages) ? history.messages : [];
    const running = Boolean(history?.runningRequestId);
    const added = messages.slice(prevCount);
    if (!running && added.length > 0 && checkFn(added, messages)) {
      return history;
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error(`timed out after ${ROUND_TIMEOUT_MS / 1000}s waiting for swarm round`);
}

async function waitForText(page, pattern, timeout = 30000) {
  const re = pattern instanceof RegExp ? pattern : new RegExp(escapeRegex(pattern));
  await page.getByText(re).or(page.getByRole('button', { name: re })).first().waitFor({ state: 'visible', timeout });
}

async function waitForSettledBubble(page, expectedText, timeout = 30000) {
  const re = new RegExp(`(^|\\n)${escapeRegex(expectedText.trim())}(\\n|$)`);
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const matched = await page.locator('flt-semantics').evaluateAll((els, source) => {
      const pattern = new RegExp(source);
      return els.some((el) => {
        const text = (el.getAttribute('aria-label') || el.textContent || '').trim();
        return pattern.test(text);
      });
    }, re.source).catch(() => false);
    if (matched) return;
    await page.waitForTimeout(300);
  }
  throw new Error(`timed out waiting for settled reply "${expectedText.trim()}"`);
}

async function openSwarmMenuAction(page, actionLabel) {
  const menuBtn = page.getByRole('button', { name: /Show menu/i }).last();
  await tapLocator(page, menuBtn, 0.5);
  await page.waitForTimeout(300);
  const exactRe = new RegExp(`^${escapeRegex(actionLabel)}$`);
  for (const cand of [
    page.getByRole('button', { name: exactRe }).last(),
    page.getByRole('menuitem', { name: exactRe }).last(),
    page.getByText(actionLabel, { exact: true }).last(),
  ]) {
    if (await cand.isVisible({ timeout: 2000 }).catch(() => false)) {
      await tapLocator(page, cand, 0.5);
      return;
    }
  }
  throw new Error(`menu action not visible: ${actionLabel}`);
}

async function main() {
  await preflight();

  const results = [];
  const allErrors = [];
  let tokenRecord = null;
  let peerChild = null;
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
        await cleanupTestData(tokenRecord.token, [ROOT, SWARM_HOST_DIR]);
      } catch (err) {
        console.error(`cleanup warning: ${err.message}`);
      }
      deleteTestToken(tokenRecord);
      tokenRecord = null;
    }
    if (peerChild) {
      await stopChild(peerChild);
      peerChild = null;
    }
  };

  const onSignal = (signal) => {
    cleanup().finally(() => process.exit(signal === 'SIGINT' ? 130 : 143));
  };
  process.once('SIGINT', onSignal);
  process.once('SIGTERM', onSignal);

  const runCheck = async (name, shotTargets, tracked, fn, { allow } = {}) => {
    const targets = Array.isArray(shotTargets) ? shotTargets : (shotTargets ? [shotTargets] : []);
    const primaryShot = targets[0] ? path.join(SHOTS, targets[0].file) : '-';
    const starts = tracked.map(({ errors }) => errors.length);
    if (allow) {
      for (const item of tracked) {
        const rule = typeof allow === 'function' ? allow : allow[item.key];
        if (rule) item.setAllow(rule);
      }
    }
    try {
      await fn();
      for (const t of targets) {
        await t.page.screenshot({ path: path.join(SHOTS, t.file) });
      }
      const newErrs = [];
      tracked.forEach(({ key, errors }, i) => {
        for (const e of errors.slice(starts[i])) newErrs.push(`${key}: ${e}`);
      });
      results.push({ ok: newErrs.length === 0, name, shotPath: primaryShot, error: newErrs[0] || '' });
    } catch (err) {
      for (const t of targets) {
        await t.page.screenshot({ path: path.join(SHOTS, t.file) }).catch(() => {});
      }
      results.push({ ok: false, name, shotPath: primaryShot, error: err.message || String(err) });
    } finally {
      for (const item of tracked) item.setAllow(null);
    }
  };

  try {
    tokenRecord = createTestToken();
    const hostToken = tokenRecord.token;
    const peerToken = crypto.randomBytes(24).toString('hex');

    await cleanupTestData(hostToken, [ROOT, SWARM_HOST_DIR]);
    peerChild = await startPeerServer(peerToken);

    const hostWorkdirInfo = await api(hostToken, 'GET', '/api/workdir');
    const hostDefaultDir = hostWorkdirInfo?.defaultDir || hostWorkdirInfo?.workdir || ROOT;
    const hostModels = await getClaudeModels(hostToken, BASE_URL, ROOT);
    const peerModels = await getClaudeModels(peerToken, PEER_URL, SWARM_PEER_DIR);
    // Remote swarm sessions inherit Main's settings on the peer, so pin haiku early.
    await api(peerToken, 'POST', '/api/agent-settings', {
      agent: 'claude',
      model: peerModels.haiku.id,
    }, { baseUrl: PEER_URL, workdir: SWARM_PEER_DIR });

    const machines = [
      { id: HOST_ID, name: HOST_NAME, baseUrl: BASE_URL, token: hostToken, workdir: ROOT },
      { id: PEER_ID_MACHINE, name: PEER_NAME, baseUrl: PEER_URL, token: peerToken, workdir: SWARM_PEER_DIR },
    ];

    const { chromium } = loadPlaywright();
    browser = await chromium.launch();

    const devA = await openRelayPage(browser, {
      machines,
      activeMachineId: HOST_ID,
      deviceId: 'relay-web-test-device-a',
      viewport: VIEWPORTS.desktop,
    });
    let devB = null;
    let group = null;
    let peerSessionId = null;

    try {
      // S1: Create multi-machine swarm through the UI form.
      await runCheck('S1-create', { page: devA.page, file: 'swarm-s1-create.png' }, [{ key: 'A', ...devA }], async () => {
        const { page } = devA;
        await openSwarmScreen(page);
        await page.getByRole('button', { name: /^New swarm$/ }).first().click();
        await page.getByRole('textbox').first().waitFor({ state: 'visible', timeout: 10000 });
        // Wait until the peer machine finishes fetching its usable agents.
        await page.getByText(PEER_NAME, { exact: true }).waitFor({ state: 'visible', timeout: 15000 });
        const claudeChips = page.getByRole('checkbox', { name: /^Claude Code$/ });
        await claudeChips.nth(1).waitFor({ state: 'visible', timeout: 15000 });

        await fillBox(page, page.getByRole('textbox').first(), SWARM_NAME);

        // Add and configure local Claude Code member.
        await clickChip(page, 'Claude Code');
        await page.waitForTimeout(800);
        await clickChip(page, 'Claude Code');
        await page.getByText('Work tree', { exact: true }).waitFor({ state: 'visible', timeout: 10000 });
        await selectDropdownOption(page, hostModels.defaultModel.label, hostModels.haiku.label);
        const localBoxes = page.getByRole('textbox');
        // SwarmFormDialog still has Swarm name textbox underneath; the two newest are Nickname and Prompt.
        await fillBox(page, localBoxes.nth((await localBoxes.count()) - 2), '架构师');
        await tapLocator(page, page.getByRole('button', { name: /^Browse$/ }).last(), 0.5);
        await pickWorkTreeInDialog(page, hostDefaultDir, SWARM_HOST_DIR);
        await tapLocator(page, page.getByRole('button', { name: /^OK$/ }).last(), 0.5);
        await page.getByRole('checkbox', { name: /^架构师/ }).last().waitFor({ state: 'visible', timeout: 10000 });

        // Add and configure remote Claude Code member on Relay Peer Test.
        await clickChip(page, 'Claude Code');
        await page.waitForTimeout(500);
        await clickChip(page, 'Claude Code');
        await page.getByText('Work directory on that machine', { exact: true }).waitFor({ state: 'visible', timeout: 10000 });
        const peerBoxes = page.getByRole('textbox');
        await fillBox(page, peerBoxes.nth((await peerBoxes.count()) - 2), '评审');
        await waitForText(page, SWARM_PEER_DIR, 10000);
        await tapLocator(page, page.getByRole('button', { name: /^OK$/ }).last(), 0.5);
        await page.getByRole('checkbox', { name: /^评审/ }).last().waitFor({ state: 'visible', timeout: 10000 });

        await tapLocator(page, page.getByRole('button', { name: /^Create$/ }).last(), 0.5);
        await waitForText(page, SWARM_NAME, 15000);
        await page.waitForTimeout(800);

        const groupsRes = await api(hostToken, 'GET', '/api/groups');
        group = (groupsRes?.groups || []).find((g) => g.name === SWARM_NAME);
        if (!group) throw new Error('created swarm not found in GET /api/groups');
        if (!group.members.includes('claude') || !group.members.includes(REMOTE_KEY)) {
          throw new Error(`unexpected swarm members: ${JSON.stringify(group.members)}`);
        }
        if (group.workdir !== SWARM_HOST_DIR) {
          throw new Error(`unexpected swarm workdir: ${group.workdir}`);
        }
        if (group.memberConfigs?.claude?.model !== hostModels.haiku.id) {
          throw new Error(`host member model mismatch: ${group.memberConfigs?.claude?.model}`);
        }
        peerSessionId = group.memberConfigs?.[REMOTE_KEY]?.sessionId;
        if (!peerSessionId) throw new Error('remote member missing peer sessionId');
        await api(peerToken, 'POST', '/api/agent-settings', {
          agent: 'claude',
          sessionId: peerSessionId,
          model: peerModels.haiku.id,
        }, { baseUrl: PEER_URL, workdir: SWARM_PEER_DIR });
      });

      if (group) {
      // S2: No mention first -> 400 GROUP_NO_MENTION + groupNeedsMention notice.
      await runCheck(
        'S2-no-mention',
        { page: devA.page, file: 'swarm-s2-no-mention.png' },
        [{ key: 'A', ...devA }],
        async () => {
          await sendSwarmPrompt(devA.page, 'hello');
          await waitForText(devA.page, /No member has spoken yet: @mention who should answer first/, 15000);
          const history = await api(hostToken, 'GET', `/api/group/history?groupId=${encodeURIComponent(group.id)}`);
          if ((history?.messages || []).length !== 0) {
            throw new Error(`expected 0 messages after GROUP_NO_MENTION, got ${history.messages.length}`);
          }
        },
        {
          allow: (entry) => /^http 400: POST .*\/api\/group\/chat$/.test(entry) ||
            /^console: Failed to load resource: the server responded with a status of 400\b/.test(entry),
        },
      );

      // S3: Non-ASCII mention without space.
      await runCheck('S3-non-ascii', { page: devA.page, file: 'swarm-s3-non-ascii.png' }, [{ key: 'A', ...devA }], async () => {
        const before = (await api(hostToken, 'GET', `/api/group/history?groupId=${encodeURIComponent(group.id)}`))?.messages?.length || 0;
        await sendSwarmPrompt(devA.page, '@架构师只回复 OK1');
        const history = await waitForGroupRound(hostToken, group.id, before, (added) =>
          added.some((m) => m.role === 'assistant' && m.metadata?.author === 'claude' && !m.metadata?.streaming));
        const reply = history.messages.slice(before).find((m) => m.role === 'assistant' && m.metadata?.author === 'claude');
        if (!reply || !String(reply.content || '').includes('OK1')) {
          throw new Error(`expected host reply containing OK1, got: ${JSON.stringify(reply?.content)}`);
        }
        await waitForSettledBubble(devA.page, reply.content, 15000);
        await devA.page.waitForTimeout(500);
      });

      // S4: Remote member turn verified on peer backend.
      await runCheck('S4-remote', { page: devA.page, file: 'swarm-s4-remote.png' }, [{ key: 'A', ...devA }], async () => {
        const before = (await api(hostToken, 'GET', `/api/group/history?groupId=${encodeURIComponent(group.id)}`))?.messages?.length || 0;
        await sendSwarmPrompt(devA.page, '@评审 只回复 OK2');
        const history = await waitForGroupRound(hostToken, group.id, before, (added) =>
          added.some((m) => m.role === 'assistant' && m.metadata?.author === REMOTE_KEY && !m.metadata?.streaming));
        const reply = history.messages.slice(before).find((m) => m.role === 'assistant' && m.metadata?.author === REMOTE_KEY);
        if (!reply || !String(reply.content || '').includes('OK2')) {
          throw new Error(`expected peer reply containing OK2, got: ${JSON.stringify(reply?.content)}`);
        }
        await waitForSettledBubble(devA.page, reply.content, 15000);

        const peerHistory = await api(
          peerToken,
          'GET',
          `/api/history?agent=claude&sessionId=${encodeURIComponent(peerSessionId)}`,
          undefined,
          { baseUrl: PEER_URL, workdir: SWARM_PEER_DIR },
        );
        const peerReply = (peerHistory?.messages || []).find((m) => m.role === 'assistant' && String(m.content || '').includes('OK2'));
        if (!peerReply) throw new Error('peer backend history does not contain the OK2 turn');
        await devA.page.waitForTimeout(500);
      });

      // Open second device (page B) for S5 and S6.
      devB = await openRelayPage(browser, {
        machines,
        activeMachineId: HOST_ID,
        deviceId: 'relay-web-test-device-b',
        viewport: VIEWPORTS.desktop,
      });
      await openSwarmScreen(devB.page);
      await selectSwarmIfNeeded(devB.page, SWARM_NAME);
      await waitForText(devB.page, /OK2/, 15000);

      // S5: Follow-up without mention goes to last speaker (评审) and updates device B live.
      await runCheck(
        'S5-followup-2dev',
        [
          { page: devA.page, file: 'swarm-s5-device-a.png' },
          { page: devB.page, file: 'swarm-s5-device-b.png' },
        ],
        [{ key: 'A', ...devA }, { key: 'B', ...devB }],
        async () => {
          const before = (await api(hostToken, 'GET', `/api/group/history?groupId=${encodeURIComponent(group.id)}`))?.messages?.length || 0;
          await sendSwarmPrompt(devA.page, '再说一次，只回复 OK3');
          const history = await waitForGroupRound(hostToken, group.id, before, (added) =>
            added.some((m) => m.role === 'assistant' && m.metadata?.author === REMOTE_KEY && !m.metadata?.streaming));
          const reply = history.messages.slice(before).find((m) => m.role === 'assistant');
          if (!reply || reply.metadata?.author !== REMOTE_KEY || !String(reply.content || '').includes('OK3')) {
            throw new Error(`expected follow-up from ${REMOTE_KEY} with OK3, got: ${JSON.stringify(reply)}`);
          }
          await waitForSettledBubble(devA.page, reply.content, 15000);
          await waitForSettledBubble(devB.page, reply.content, 15000);
          await devB.page.waitForTimeout(500);
        },
      );

      // S6: SSE reconnect after offline window during a round.
      await runCheck(
        'S6-sse-reconnect',
        { page: devB.page, file: 'swarm-s6-reconnect.png' },
        [{ key: 'A', ...devA }, { key: 'B', ...devB }],
        async () => {
          const s6Net = [];
          const onReq = (req) => { if (req.url().includes('/api/')) s6Net.push(`REQ ${req.method()} ${new URL(req.url()).pathname}`); };
          const onRes = (res) => { if (res.url().includes('/api/')) s6Net.push(`RES ${res.status()} ${new URL(res.url()).pathname}`); };
          const onFail = (req) => { if (req.url().includes('/api/')) s6Net.push(`FAIL ${new URL(req.url()).pathname} ${req.failure()?.errorText}`); };
          devB.page.on('request', onReq);
          devB.page.on('response', onRes);
          devB.page.on('requestfailed', onFail);
          try {
            const before = (await api(hostToken, 'GET', `/api/group/history?groupId=${encodeURIComponent(group.id)}`))?.messages?.length || 0;
            await sendSwarmPrompt(devA.page, '@架构师只回复 OK4');
            await devB.page.context().setOffline(true);
            await devB.page.waitForTimeout(5000);
            await devB.page.context().setOffline(false);

            const history = await waitForGroupRound(hostToken, group.id, before, (added) =>
              added.some((m) => m.role === 'assistant' && m.metadata?.author === 'claude' && !m.metadata?.streaming));
            const reply = history.messages.slice(before).find((m) => m.role === 'assistant' && m.metadata?.author === 'claude');
            if (!reply || !String(reply.content || '').includes('OK4')) {
              throw new Error(`expected OK4 reply, got: ${JSON.stringify(reply?.content)}`);
            }
            try {
              await waitForSettledBubble(devB.page, reply.content, 30000);
            } catch (err) {
              throw new Error(`${err.message} (devB net: ${s6Net.join(' | ')})`, { cause: err });
            }
            // Send button visible and Cancel (Stop) button absent once the round finishes.
            await devB.page.getByRole('button', { name: /^Send$/ }).first().waitFor({ state: 'visible', timeout: 15000 });
            const stopVisible = await devB.page.getByRole('button', { name: /^Cancel$/ }).first().isVisible().catch(() => false);
            if (stopVisible) throw new Error('Stop/Cancel button remained visible on device B after reconnect');
            await devB.page.waitForTimeout(500);
          } finally {
            devB.page.off('request', onReq);
            devB.page.off('response', onRes);
            devB.page.off('requestfailed', onFail);
          }
        },
        {
          allow: {
            B: (entry) => /requestfailed:|ERR_INTERNET_DISCONNECTED|ERR_ABORTED|Failed to fetch/i.test(entry),
          },
        },
      );

      await devB.page.close();
      for (const err of devB.errors) allErrors.push(`device-b: ${err}`);
      devB = null;

      // S7: Dropped send request recovers via history without duplicate or error.
      await runCheck(
        'S7-dropped-send',
        { page: devA.page, file: 'swarm-s7-dropped-send.png' },
        [{ key: 'A', ...devA }],
        async () => {
          const before = (await api(hostToken, 'GET', `/api/group/history?groupId=${encodeURIComponent(group.id)}`))?.messages?.length || 0;
          let intercepted = false;
          const handler = async (route) => {
            if (intercepted) return route.continue();
            intercepted = true;
            await route.fetch();
            await route.abort();
          };
          await devA.page.route('**/api/group/chat', handler);
          try {
            await sendSwarmPrompt(devA.page, '@架构师只回复 OK5');
            const history = await waitForGroupRound(hostToken, group.id, before, (added) =>
              added.some((m) => m.role === 'assistant' && m.metadata?.author === 'claude' && !m.metadata?.streaming));
            const humanMsgs = history.messages.slice(before).filter((m) => m.role === 'user' && String(m.content || '').includes('OK5'));
            if (humanMsgs.length !== 1) {
              throw new Error(`expected exactly 1 human OK5 message, got ${humanMsgs.length}`);
            }
            const reply = history.messages.slice(before).find((m) => m.role === 'assistant' && String(m.content || '').includes('OK5'));
            if (!reply) throw new Error('expected assistant reply containing OK5');
            await waitForSettledBubble(devA.page, reply.content, 15000);
            await devA.page.getByRole('button', { name: /^Send$/ }).first().waitFor({ state: 'visible', timeout: 15000 });
            const hasErrBanner = await devA.page.getByText(/Network error|cannot reach/i).first().isVisible().catch(() => false);
            if (hasErrBanner) throw new Error('network error banner remained after dropped send recovery');
            const composerVal = await devA.page.getByRole('textbox').last().inputValue().catch(() => '');
            if (composerVal.includes('OK5')) throw new Error('composer restored failed prompt after dropped send');
          } finally {
            await devA.page.unroute('**/api/group/chat', handler);
          }
        },
        { allow: (entry) => /requestfailed: POST .*\/api\/group\/chat|ERR_FAILED|ERR_ABORTED|Failed to fetch/i.test(entry) },
      );

      // S8: Hop limit stops ping-pong and shows unsummoned notice; editing roles keeps stored models.
      await runCheck('S8-hop-limit', { page: devA.page, file: 'swarm-s8-hop-limit.png' }, [{ key: 'A', ...devA }], async () => {
        const { page } = devA;
        await openSwarmMenuAction(page, 'Manage members');
        await page.getByText('Manage members', { exact: true }).waitFor({ state: 'visible', timeout: 10000 });

        await clickChip(page, '架构师', { last: true });
        await page.getByText('Work tree', { exact: true }).waitFor({ state: 'visible', timeout: 10000 });
        await fillBox(page, page.getByRole('textbox').last(), 'Always reply with exactly: @评审 ping');
        await tapLocator(page, page.getByRole('button', { name: /^OK$/ }).last(), 0.5);
        await page.waitForTimeout(400);

        await clickChip(page, '评审', { last: true });
        await page.getByText('Work directory on that machine', { exact: true }).waitFor({ state: 'visible', timeout: 10000 });
        await fillBox(page, page.getByRole('textbox').last(), 'Always reply with exactly: @架构师 pong');
        await tapLocator(page, page.getByRole('button', { name: /^OK$/ }).last(), 0.5);
        await page.waitForTimeout(400);

        await tapLocator(page, page.getByRole('button', { name: /^OK$/ }).last(), 0.5);
        await page.getByText('Manage members', { exact: true }).waitFor({ state: 'hidden', timeout: 10000 });

        const groupsRes = await api(hostToken, 'GET', '/api/groups');
        const updated = (groupsRes?.groups || []).find((g) => g.id === group.id);
        if (updated?.memberConfigs?.claude?.model !== hostModels.haiku.id) {
          throw new Error(`editing roles wiped host model: ${updated?.memberConfigs?.claude?.model}`);
        }
        const peerSettings = await api(
          peerToken,
          'GET',
          `/api/agent-settings?agent=claude&sessionId=${encodeURIComponent(peerSessionId)}`,
          undefined,
          { baseUrl: PEER_URL, workdir: SWARM_PEER_DIR },
        );
        if (peerSettings?.settings?.model !== peerModels.haiku.id) {
          throw new Error(`editing roles changed peer model: ${peerSettings?.settings?.model}`);
        }

        const before = (await api(hostToken, 'GET', `/api/group/history?groupId=${encodeURIComponent(group.id)}`))?.messages?.length || 0;
        await sendSwarmPrompt(page, '@架构师 start');
        await waitForGroupRound(hostToken, group.id, before, (added) =>
          added.filter((m) => m.role === 'assistant' && !m.metadata?.streaming).length >= 2);
        await waitForText(page, /This round reached its hand-off limit and did not summon:/, 30000);
        await page.waitForTimeout(500);
      });

      // S9: Clear transcript requires confirmation (Cancel keeps, Clear empties).
      await runCheck('S9-clear-confirm', { page: devA.page, file: 'swarm-s9-clear.png' }, [{ key: 'A', ...devA }], async () => {
        const { page } = devA;
        await openSwarmMenuAction(page, 'Clear transcript');
        await waitForText(page, 'Clear this swarm?', 10000);
        await tapLocator(page, page.getByRole('button', { name: /^Cancel$/ }).last(), 0.5);
        await page.getByText('Clear this swarm?', { exact: true }).waitFor({ state: 'hidden', timeout: 10000 });

        const afterCancel = await api(hostToken, 'GET', `/api/group/history?groupId=${encodeURIComponent(group.id)}`);
        if ((afterCancel?.messages || []).length === 0) {
          throw new Error('Cancel cleared the swarm transcript');
        }

        await openSwarmMenuAction(page, 'Clear transcript');
        await waitForText(page, 'Clear this swarm?', 10000);
        await tapLocator(page, page.getByRole('button', { name: /^Clear$/ }).last(), 0.5);
        await waitForText(page, /Mention a member with @/, 15000);

        const afterClear = await api(hostToken, 'GET', `/api/group/history?groupId=${encodeURIComponent(group.id)}`);
        if ((afterClear?.messages || []).length !== 0) {
          throw new Error(`expected empty transcript after Clear, got ${afterClear.messages.length}`);
        }
        await page.waitForTimeout(400);
      });
      }
    } finally {
      if (devB) {
        for (const err of devB.errors) allErrors.push(`device-b: ${err}`);
        await devB.page.close().catch(() => {});
      }
      for (const err of devA.errors) allErrors.push(`device-a: ${err}`);
      await devA.page.close().catch(() => {});
    }

    // S10: Mobile machine switch to Relay Peer Test and back, checking quota strip on both.
    const mobile = await openRelayPage(browser, {
      machines,
      activeMachineId: HOST_ID,
      deviceId: 'relay-web-test-mobile',
      viewport: VIEWPORTS.mobile,
    });
    try {
      const usageHits = [];
      mobile.page.on('response', (res) => {
        if (res.url().includes('/api/usage') && res.ok()) usageHits.push(res.url());
      });
      await runCheck(
        'S10-machine-switch',
        { page: mobile.page, file: 'swarm-s10-host.png' },
        [{ key: 'mobile', ...mobile }],
        async () => {
          const { page } = mobile;
          // Open Claude Code solo chat so QuotaStrip renders above the composer.
          await openDrawerIfMobile(page, true);
          await page.getByRole('button', { name: /Claude Code/ }).first().click();
          await page.getByRole('textbox').first().waitFor({ state: 'visible', timeout: 15000 });
          await waitForText(page, /\d+%/, 20000);
          await page.waitForTimeout(600);

          // Switch to Relay Peer Test via drawer -> Settings -> Machine credentials.
          const switchTo = async (machineName, expectedBaseUrl) => {
            const beforeHits = usageHits.length;
            await openDrawerIfMobile(page, true);
            await page.getByRole('button', { name: /^Settings$/ }).click();
            const tile = page.getByRole('button', { name: new RegExp(escapeRegex(machineName)) }).first();
            await tapLocator(page, tile, 0.35);
            await page.waitForTimeout(500);
            await tapLocator(page, page.getByRole('button', { name: /^Back$/ }).first(), 0.5);
            await page.getByRole('textbox').first().waitFor({ state: 'visible', timeout: 15000 });
            const deadline = Date.now() + 20000;
            while (Date.now() < deadline) {
              if (usageHits.slice(beforeHits).some((u) => u.startsWith(expectedBaseUrl))) break;
              await page.waitForTimeout(300);
            }
            if (!usageHits.slice(beforeHits).some((u) => u.startsWith(expectedBaseUrl))) {
              throw new Error(`no /api/usage response from ${expectedBaseUrl} after switching to ${machineName}`);
            }
            await waitForText(page, /\d+%/, 20000);
            await page.waitForTimeout(600);
          };

          await switchTo(PEER_NAME, PEER_URL);
          await page.screenshot({ path: path.join(SHOTS, 'swarm-s10-peer.png') });
          await switchTo(HOST_NAME, BASE_URL);
        },
      );
    } finally {
      for (const err of mobile.errors) allErrors.push(`mobile: ${err}`);
      await mobile.page.close().catch(() => {});
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
