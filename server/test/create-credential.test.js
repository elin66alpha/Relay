'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { detectTunnelUrl } = require('../scripts/create-credential');

function writeLog(file, url, ageSeconds) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `INF Your quick Tunnel has been created! Visit it at:\n${url}\n`);
  const when = new Date(Date.now() - ageSeconds * 1000);
  fs.utimesSync(file, when, when);
}

test('the Quick Tunnel URL comes from the newest tunnel log of any service manager', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-credential-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, 'home');
  const serverDir = path.join(root, 'install', 'server');
  const where = { home, serverDir };
  assert.equal(detectTunnelUrl({}, where), '');

  // PM2 on Linux, then the macOS LaunchAgent, then Windows setup's logs folder.
  writeLog(path.join(home, '.pm2', 'logs', 'relay-tunnel-error.log'), 'https://linux-old.trycloudflare.com', 300);
  assert.equal(detectTunnelUrl({}, where), 'https://linux-old.trycloudflare.com');
  writeLog(path.join(home, 'Library', 'Logs', 'Relay', 'tunnel.err.log'), 'https://macos.trycloudflare.com', 200);
  assert.equal(detectTunnelUrl({}, where), 'https://macos.trycloudflare.com');
  writeLog(path.join(root, 'install', 'logs', 'tunnel.err.log'), 'https://windows.trycloudflare.com', 100);
  assert.equal(detectTunnelUrl({}, where), 'https://windows.trycloudflare.com');
});
