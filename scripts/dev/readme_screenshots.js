#!/usr/bin/env node
// Recaptures the README screenshots (docs/screenshots/*.png, English and
// Chinese) against an isolated demo backend. See docs/handbook.md,
// "Refreshing README screenshots".
//
//   node scripts/dev/readme_screenshots.js <wallpaper image> [--mobile-zh]
'use strict';
/* global createImageBitmap, document */

const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const { execFileSync, spawn } = require('node:child_process');
const {
  DRAWER,
  WEB_BUILD_HINT,
  enableSemantics,
  loadPlaywright,
  runSteps,
  seedStorage,
} = require('./lib/relay_web');

const REPO = path.resolve(__dirname, '../..');
const MOBILE_ZH = process.argv.includes('--mobile-zh');
const OUT = path.join(REPO, 'docs', 'screenshots', ...(MOBILE_ZH ? ['mobile-zh-9x16'] : []));
const WEB = path.join(REPO, 'app', 'shell', 'build', 'web');
// The path is visible in the screenshots, so it stays fixed.
const ROOT = '/tmp/relay-demo';
const SERVER = path.join(ROOT, 'server');
const WORKDIR = path.join(ROOT, 'projects', 'aurora-api');
const PORT = Number(process.env.DEMO_PORT || 8790);
const BASE_URL = `http://127.0.0.1:${PORT}`;
const PREVIEW_PORT = PORT + 1;
const TOKEN = 'relay-demo-screenshot-token-0000000000000000';
const DARK_OPACITY = Number(process.env.WALLPAPER_DARK_OPACITY || 0.6);
const SEP = '\u0000';
// Chat times are today's date at fixed hours; the browser runs in UTC to match.
const day = new Date().toISOString().slice(0, 10);
const at = (hm) => `${day}T${hm}:00.000Z`;

// Viewport, device pixel ratio and the actions that reach each screen.
const OPEN_FILES = [{ tap: DRAWER }, { button: ['File system', '文件系统'] }];
const OPEN_BROWSER = [{ tap: DRAWER }, { button: ['Browser', '浏览器'] }];
const OPEN_IMAGE = [...OPEN_FILES, { button: ['ferrari.png', 'ferrari.png'] }];
const SHOTS = [
  { name: 'relay-overview-web', size: [1440, 960, 1], steps: [] },
  { name: 'relay-chat-web', size: [1440, 960, 1], steps: [{ tap: [104, 308] }] },
  { name: 'relay-chat-mobile', size: [400, 820, 2], steps: [{ tap: DRAWER }, { tap: [104, 308] }] },
  {
    name: 'relay-swarm-mobile',
    size: [400, 820, 2],
    steps: [{ tap: DRAWER }, { tap: [100, 212] }],
  },
  { name: 'relay-files-mobile', size: [400, 820, 2], steps: OPEN_FILES },
  { name: 'relay-settings-mobile', size: [400, 820, 2], steps: [{ tap: DRAWER }, { button: ['Settings', '设置'] }] },
  { name: 'relay-tutorial-mobile', size: [400, 820, 2], steps: [{ button: ['Browse all articles', '浏览全部教程'] }], loads: true },
];

// Same layout as the first phone set, rendered at 2.5× for 1080×1920 PNGs.
const MOBILE_SHOTS = [
  { name: 'relay-overview-mobile', steps: [] },
  { name: 'relay-chat-mobile', steps: [{ tap: DRAWER }, { tap: [104, 308] }] },
  { name: 'relay-chat-empty-mobile', empty: true, steps: [{ tap: DRAWER }, { tap: [104, 308] }] },
  {
    name: 'relay-swarm-mobile',
    steps: [{ tap: DRAWER }, { tap: [100, 212] }],
  },
  { name: 'relay-files-mobile', steps: OPEN_FILES },
  { name: 'relay-browser-mobile', steps: OPEN_BROWSER, browser: true },
  { name: 'relay-image-preview-mobile', steps: OPEN_IMAGE, image: true },
  { name: 'relay-machine-mobile', steps: [{ tap: [180, 132] }] },
  { name: 'relay-quota-mobile', steps: [{ tap: DRAWER }, { tap: [100, 165] }], quota: true },
  { name: 'relay-settings-mobile', steps: [{ tap: DRAWER }, { button: ['Settings', '设置'] }] },
].map((shot) => ({ ...shot, size: [432, 768, 2.5] }));

function writeJson(name, value) {
  fs.writeFileSync(path.join(SERVER, name), JSON.stringify(value, null, 2));
}

function seed(lang, image) {
  const text = (en, zh) => lang === 'zh' ? zh : en;
  fs.rmSync(ROOT, { recursive: true, force: true });

  const files = {
    'docs/architecture.md': '# Architecture\n',
    'migrations/0007_add_invoice_index.sql':
      'CREATE INDEX invoices_customer_number ON invoices (customer_id, number);\n',
    'scripts/seed.ts': 'export {};\n',
    'src/billing/invoices.ts': 'export {};\n',
    'tests/billing.test.ts': 'export {};\n',
    'CHANGELOG.md': '# Changelog\n',
    'package.json': `${JSON.stringify({ name: 'aurora-api', version: '2.4.1' }, null, 2)}\n`,
    'README.md': '# aurora-api\n',
    'tsconfig.json': '{ "compilerOptions": { "strict": true } }\n',
  };
  for (const [rel, body] of Object.entries(files)) {
    const file = path.join(WORKDIR, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, body);
  }
  fs.copyFileSync(image, path.join(WORKDIR, 'ferrari.png'));

  // Tracked server code only, so no local deployment state is copied.
  const tracked = execFileSync('git', ['ls-files', 'server'], { cwd: REPO }).toString().trim().split('\n');
  for (const rel of tracked) {
    const dest = path.join(ROOT, rel);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(path.join(REPO, rel), dest);
  }
  fs.symlinkSync(path.join(REPO, 'server', 'node_modules'), path.join(SERVER, 'node_modules'));
  fs.mkdirSync(path.join(ROOT, 'app', 'shell', 'build'), { recursive: true });
  fs.symlinkSync(WEB, path.join(ROOT, 'app', 'shell', 'build', 'web'));

  writeJson('tokens.json', [{ id: 'demo', token: TOKEN, label: 'Relay Demo', createdAt: at('09:00'), revoked: false }]);

  const claudeContext = `${WORKDIR}${SEP}claude`;
  writeJson('chat-sessions.json', {
    [claudeContext]: {
      activeSessionId: 'default',
      sessions: [
        { id: 'default', name: 'Main', createdAt: at('09:00'), updatedAt: at('10:17') },
        { id: 'release-notes', name: text('Release notes', '发布说明'), createdAt: at('09:10'), updatedAt: at('09:40') },
        { id: 'flaky-tests', name: text('Flaky tests', '不稳定测试'), createdAt: at('09:05'), updatedAt: at('09:30') },
      ],
    },
  });

  const solo = (id, role, content, hm, extra = {}) => ({
    id,
    role,
    content,
    agent: 'claude',
    createdAt: at(hm),
    metadata: {
      agentKey: 'claude',
      agentLabel: 'Claude Code',
      sessionId: 'default',
      sessionName: 'Main',
      ...(role === 'assistant' ? { streaming: false, segments: [{ ts: at(hm), text: content }] } : {}),
      ...extra,
    },
  });
  const fixReply = [
    text('I ran `tests/billing.test.ts` 40 times and reproduced the timeout 4 times. Every failure happens when two invoices for the same customer are created in parallel.', '我运行了 40 次 `tests/billing.test.ts`，其中 4 次出现超时。每次失败都发生在为同一客户并发创建两张发票时。'),
    '',
    text('**Root cause:** `createInvoice` reads the next invoice number and then inserts it, so concurrent calls race and the second insert waits on the unique index lock.', '**根本原因：** `createInvoice` 先读取下一个发票编号，再执行插入。并发调用产生竞争，第二次插入因此等待唯一索引锁。'),
    '',
    text('I moved the read into the insert:', '我将读取编号合并到了插入语句中：'),
    '',
    '```ts',
    'const invoice = await db.one(',
    '  `INSERT INTO invoices (customer_id, number)',
    '   SELECT $1, COALESCE(MAX(number), 0) + 1',
    '   FROM invoices WHERE customer_id = $1',
    '   RETURNING *`,',
    '  [customerId],',
    ');',
    '```',
    '',
    text('The suite now passes 40/40 runs.', '修复后连续运行 40 次，全部通过。'),
  ].join('\n');
  const doneReply = [
    text('Done:', '已完成：'),
    '',
    text('- Added `creates sequential numbers under concurrency` to `tests/billing.test.ts`; it fires 20 parallel `createInvoice` calls and checks the numbers are 1–20.', '- 在 `tests/billing.test.ts` 中新增“并发创建时编号连续”的回归测试：并行调用 20 次 `createInvoice`，检查编号为 1–20。'),
    text('- Added a **Fixed** entry to `CHANGELOG.md` under 2.4.1.', '- 在 `CHANGELOG.md` 的 2.4.1 版本下添加了**修复**记录。'),
    '',
    text('`npm test` → 128 passed, 0 failed.', '`npm test` → 128 项通过，0 项失败。'),
  ].join('\n');

  const groupId = 'release-readiness';
  const groupName = text('Release readiness', '发布检查');
  const member = (id, agent, label, content, hm) => ({
    id,
    role: 'assistant',
    content,
    agent,
    createdAt: at(hm),
    metadata: {
      agentKey: agent,
      agentLabel: label,
      author: agent,
      summonedBy: 'human',
      groupId,
      groupName,
      sessionId: groupId,
      sessionName: groupName,
      streaming: false,
      segments: [{ ts: at(hm), text: content }],
    },
  });

  writeJson('chat-history.json', {
    [claudeContext]: [
      solo('u1', 'user', text('`tests/billing.test.ts` times out about one run in ten in CI. Find out why and fix it.', '`tests/billing.test.ts` 在 CI 中大约每十次运行就有一次超时。请找出原因并修复。'), '09:48'),
      solo('a1', 'assistant', fixReply, '09:50', { context: { used: 31000, size: 200000 } }),
      solo('u2', 'user', text('Nice. Add a regression test and update the changelog.', '很好，再补一个回归测试，并更新变更日志。'), '10:17'),
      solo('a2', 'assistant', doneReply, '10:17', { context: { used: 42000, size: 200000 } }),
    ],
    [`${WORKDIR}${SEP}group:${groupId}`]: [
      {
        id: 'g1',
        role: 'user',
        content: text('@Lead @Reviewer is 2.4.1 ready to ship?', '@负责人 @审查员 2.4.1 可以发布了吗？'),
        agent: 'human',
        createdAt: at('10:06'),
        metadata: { author: 'human', summonedBy: 'human', groupId, groupName, mentions: ['claude', 'codex'] },
      },
      member('g2', 'claude', text('Lead', '负责人'),
        text('The invoice race is fixed and covered by a regression test. All 128 tests pass. I would ship once the release notes are updated. @Docs can you draft them?', '发票编号的并发问题已修复，并补上了回归测试。128 项测试全部通过，更新发布说明后就可以发布。@文档 请起草发布说明。'), '10:07'),
      member('g3', 'codex', text('Reviewer', '审查员'),
        text('Reviewed the diff: the single-statement insert is correct. Migration `0007_add_invoice_index.sql` keeps the lookup fast. No blockers.', '已审查代码差异，合并后的插入语句没有问题。迁移 `0007_add_invoice_index.sql` 保证了查询速度，没有发布阻碍。'), '10:07'),
      member('g4', 'opencode', text('Docs', '文档'),
        text('Drafted the 2.4.1 notes:\n\n- **Fixed** duplicate invoice numbers under concurrent checkout\n- **Added** an index on `invoices(customer_id, number)`', '2.4.1 发布说明已起草：\n\n- **修复**并发结账时发票编号重复的问题\n- **新增** `invoices(customer_id, number)` 索引'), '10:09'),
    ],
  });

  writeJson('groups.json', {
    [WORKDIR]: {
      groups: [{
        id: groupId,
        name: groupName,
        members: ['claude', 'codex', 'opencode'],
        workdir: WORKDIR,
        memberConfigs: { claude: { nickname: text('Lead', '负责人') }, codex: { nickname: text('Reviewer', '审查员') }, opencode: { nickname: text('Docs', '文档') } },
        createdAt: at('10:00'),
        updatedAt: at('10:09'),
      }],
    },
  });
}

function startPreview(lang) {
  const text = (en, zh) => lang === 'zh' ? zh : en;
  const html = `<!doctype html>
<html lang="${lang}"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Aurora · ${text('Billing', '账单')}</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f5f6f8;color:#172b3a;font:15px system-ui,sans-serif}
header{padding:22px 24px;background:#172b3a;color:white;display:flex;align-items:center;justify-content:space-between}
header strong{font-size:22px;letter-spacing:-.7px}header span{color:#b8c9d6;font-size:12px}
main{max-width:960px;margin:auto;padding:26px 22px}small{color:#607482;font-size:11px;letter-spacing:1.4px}
h1{font-size:29px;letter-spacing:-1px;margin:8px 0}p{color:#607482;line-height:1.6;margin:0 0 22px}
.stats{display:grid;grid-template-columns:1fr 1fr;gap:12px}.card,section{background:white;border:1px solid #e0e6eb;border-radius:12px;padding:18px}
.card span{font-size:12px;color:#607482}.card strong{display:block;font-size:27px;margin:9px 0 4px}.card em{font-size:11px;font-style:normal;color:#13765e}
section{margin-top:18px}h2{font-size:16px;margin:0 0 20px}.chart{height:85px;display:flex;align-items:end;gap:12px}
.chart i{flex:1;background:#467d96;border-radius:4px 4px 0 0}.chart i:last-child{background:#172b3a}
.axis{display:flex;justify-content:space-between;font-size:10px;color:#607482;margin-top:8px}
.invoice{display:flex;justify-content:space-between;align-items:center;padding:15px 0;border-top:1px solid #edf0f3}
.invoice b{font-size:13px}.invoice span{display:block;font-size:11px;color:#607482;margin-top:4px}
.paid{background:#e5f4ec;color:#13765e;padding:5px 9px;border-radius:5px;font-size:11px}
footer{margin-top:20px;color:#607482;font-size:11px}
</style>
<header><strong>aurora<span style="color:#76b4cf"> / </span></strong><span>${text('Development preview', '开发预览')}</span></header>
<main><small>AURORA API · 2.4.1</small><h1>${text('Billing overview', '账单概览')}</h1>
<p>${text('A clear view of your invoices and revenue.', '发票与收入，一目了然。')}</p>
<div class="stats"><div class="card"><span>${text('Revenue this month', '本月收入')}</span><strong>¥48,250</strong><em>↑ 18.6% ${text('vs last month', '较上月')}</em></div>
<div class="card"><span>${text('Paid invoices', '已付发票')}</span><strong>128</strong><em>${text('All payments settled', '全部款项已结清')}</em></div></div>
<section><h2>${text('Revenue · Last 7 days', '收入 · 最近 7 天')}</h2><div class="chart">
${[36, 58, 44, 72, 62, 84, 98].map((height) => `<i style="height:${height}%"></i>`).join('')}</div>
<div class="axis"><span>${text('MON', '周一')}</span><span>${text('SUN', '周日')}</span></div></section>
<section><h2>${text('Recent invoices', '最近发票')}</h2>
${[['1048', 'Northstar Studio', '¥2,400'], ['1047', 'Orbit Labs', '¥1,850'], ['1046', 'Acme Design', '¥3,200']].map(([id, name, amount]) =>
    `<div class="invoice"><div><b>${name}</b><span>INV-${id} · ${amount}</span></div><label class="paid">${text('Paid', '已付款')}</label></div>`).join('')}
</section><footer>localhost:${PREVIEW_PORT} · ${text('Served on your backend machine', '运行在你的后端机器上')}</footer></main></html>`;
  const server = http.createServer((_req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(PREVIEW_PORT, '127.0.0.1', () => resolve(server));
  });
}

async function startServer(browserPath) {
  // Match Playwright's sandbox setting only for this isolated localhost demo.
  const launcher = path.join(ROOT, 'chromium-demo');
  const quotedBrowser = `'${browserPath.replace(/'/g, "'\\''")}'`;
  fs.writeFileSync(launcher, `#!/bin/sh\nexec ${quotedBrowser} --no-sandbox "$@"\n`, { mode: 0o700 });
  // The shell may carry the real deployment's settings; the demo must not use them.
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) =>
    !/^(PORT|HOST|PUBLIC_BASE_URL|RELAY_.*|ENABLE_.*)$/.test(key)));
  const server = spawn(process.execPath, ['server.js'], {
    cwd: SERVER,
    stdio: ['ignore', 'ignore', 'inherit'],
    env: {
      ...env,
      PORT: String(PORT),
      HOST: '127.0.0.1',
      RELAY_DEFAULT_DIR: WORKDIR,
      RELAY_FS_ROOTS: path.join(ROOT, 'projects'),
      RELAY_BROWSER: launcher,
      ENABLE_QUOTA_WATCH: 'false',
      ENABLE_CLAUDE_KEEPALIVE: 'false',
    },
  });
  for (let i = 0; i < 30; i += 1) {
    if (server.exitCode !== null) throw new Error('demo server exited; is the port free?');
    try {
      if ((await fetch(BASE_URL)).ok) return server;
    } catch (_) {
      // Not listening yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  server.kill();
  throw new Error(`demo server did not answer on ${BASE_URL}`);
}

async function prepareWallpaperPref(page, wallpaper, darkOpacity) {
  return page.evaluate(async ({ wallpaper: raw, darkOpacity: dark }) => {
    const b64 = (buffer) => {
      let text = '';
      for (const byte of new Uint8Array(buffer)) text += String.fromCharCode(byte);
      return btoa(text);
    };
    // Prepare the wallpaper the way the Web client does on import: at most
    // 1920 px on the long edge, JPEG, shrunk until it fits 256 KB.
    const source = Uint8Array.from(atob(raw), (c) => c.charCodeAt(0));
    const bitmap = await createImageBitmap(new Blob([source]));
    const canvas = document.createElement('canvas');
    const scale = Math.min(1, 1920 / Math.max(bitmap.width, bitmap.height));
    let w = Math.round(bitmap.width * scale);
    let h = Math.round(bitmap.height * scale);
    let jpeg;
    for (;;) {
      canvas.width = w;
      canvas.height = h;
      const paint = canvas.getContext('2d');
      paint.fillStyle = '#808080';
      paint.fillRect(0, 0, w, h);
      paint.drawImage(bitmap, 0, 0, w, h);
      jpeg = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', 0.86));
      if (jpeg.size <= 256 * 1024) break;
      w = Math.round(w * 0.8);
      h = Math.round(h * 0.8);
    }
    return JSON.stringify({
      image: b64(await jpeg.arrayBuffer()), light: 0.8, dark, blur: 6, tint: 0.55,
    });
  }, { wallpaper, darkOpacity });
}

async function shoot(browser, wallpaper, lang, shot) {
  const [width, height, dpr] = shot.size;
  const page = await browser.newPage({
    viewport: { width, height },
    deviceScaleFactor: dpr,
    timezoneId: 'UTC',
    locale: lang === 'zh' ? 'zh-CN' : 'en-US',
  });
  let previewDownloaded = false;
  let browserFrames = 0;
  let browserUrl = '';
  page.on('response', (response) => {
    if (response.url().includes('/api/fs/download?') && response.url().includes('ferrari.png') && response.ok()) {
      previewDownloaded = true;
    }
  });
  page.on('websocket', (socket) => {
    if (!socket.url().includes('/api/browser/connect?')) return;
    socket.on('framereceived', ({ payload }) => {
      if (Buffer.isBuffer(payload)) {
        browserFrames += 1;
      } else {
        const message = JSON.parse(payload);
        if (message.type === 'url') browserUrl = message.url;
      }
    });
  });
  if (shot.empty) {
    // Empty only this browser's history; the demo's translated chat stays intact.
    await page.route('**/api/history?*', async (route) => {
      const response = await route.fetch();
      const history = await response.json();
      await route.fulfill({ response, json: { ...history, messages: [] } });
    });
  }
  await page.goto(BASE_URL);
  const wallpaperPref = await prepareWallpaperPref(page, wallpaper, DARK_OPACITY);
  await seedStorage(page, {
    machineId: 'demo',
    name: 'Relay Demo',
    baseUrl: BASE_URL,
    token: TOKEN,
    prefs: {
      'relay.language.v1': lang,
      'relay.theme_mode.v1': 'dark',
      'relay.wallpaper.v2': wallpaperPref,
    },
  });
  await page.reload();
  await page.waitForTimeout(6000);
  await enableSemantics(page);
  await runSteps(page, shot.steps, { lang });
  if (shot.browser) {
    await page.getByRole('textbox').fill(`http://127.0.0.1:${PREVIEW_PORT}`);
    const framesBeforeNavigation = browserFrames;
    await page.getByRole('textbox').press('Enter');
    await page.waitForTimeout(4000);
    assert(browserUrl.startsWith(`http://127.0.0.1:${PREVIEW_PORT}`), 'Browser must navigate to the localhost demo');
    assert(browserFrames > framesBeforeNavigation, 'Browser screenshot must contain a streamed frame');
  }
  if (shot.image) {
    assert(previewDownloaded, 'Image preview must download the demo Ferrari image');
    await page.getByRole('img').waitFor({ state: 'visible' });
    assert(!(await page.locator('body').innerText()).match(/Cannot preview|无法预览/), 'Image preview must render successfully');
  }
  // The tutorial's search field appears once every article has loaded; the
  // extra wait lets Flutter fetch the CJK glyphs that new text needs.
  if (shot.loads) {
    await page.getByRole('textbox').waitFor({ timeout: 60000 });
    await page.waitForTimeout(4000);
  }
  if (shot.quota) {
    assert(!(await page.locator('body').innerText()).match(/Loading quota|正在查询额度/), 'Quota queries must finish before capture');
  }
  const file = path.join(OUT, `${shot.name}${lang === 'zh' ? '-zh' : ''}.png`);
  await page.screenshot({ path: file });
  await page.close();
  console.log(`wrote ${path.relative(REPO, file)}`);
}

async function main() {
  const image = process.argv[2];
  if (!image || !fs.existsSync(image)) {
    console.error('usage: node scripts/dev/readme_screenshots.js <wallpaper image> [--mobile-zh]');
    process.exit(2);
  }
  if (!fs.existsSync(path.join(WEB, 'index.html'))) {
    console.error(`build the Web client first: ${WEB_BUILD_HINT}`);
    process.exit(2);
  }
  const { chromium } = loadPlaywright();
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch();
  try {
    const wallpaper = fs.readFileSync(image).toString('base64');
    for (const lang of MOBILE_ZH ? ['zh'] : ['en', 'zh']) {
      seed(lang, image);
      const preview = await startPreview(lang);
      let server;
      try {
        server = await startServer(chromium.executablePath());
        const shots = MOBILE_ZH ? MOBILE_SHOTS : SHOTS;
        for (const shot of shots) await shoot(browser, wallpaper, lang, shot);
      } finally {
        if (server) {
          server.kill();
          await new Promise((resolve) => server.once('exit', resolve));
        }
        await new Promise((resolve) => preview.close(resolve));
      }
    }
  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
