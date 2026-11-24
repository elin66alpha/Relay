'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

test('keep-running starts the backend again after it exits', { timeout: 15000 }, async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-keep-running-'));
  const runs = path.join(root, 'runs');
  fs.mkdirSync(path.join(root, 'scripts'));
  fs.copyFileSync(path.join(__dirname, '../scripts/keep-running.js'), path.join(root, 'scripts', 'keep-running.js'));
  // A backend that crashes as soon as it starts.
  fs.writeFileSync(path.join(root, 'server.js'), `require('fs').appendFileSync(${JSON.stringify(runs)}, 'run\\n'); process.exit(1);`);
  const supervisor = spawn(process.execPath, [path.join(root, 'scripts', 'keep-running.js')], { stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  supervisor.stderr.on('data', (chunk) => { stderr += chunk; });
  t.after(() => {
    supervisor.kill();
    fs.rmSync(root, { recursive: true, force: true });
  });
  const count = () => (fs.existsSync(runs) ? fs.readFileSync(runs, 'utf8').split('\n').filter(Boolean).length : 0);
  const deadline = Date.now() + 12000;
  while (count() < 2 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 200));
  assert.equal(count() >= 2, true, 'a crashed backend is started again');
  assert.match(stderr, /Relay backend exited \(1\); starting it again in 5 seconds/);
});
