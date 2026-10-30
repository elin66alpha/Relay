'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

// A fake `opencode` that counts its runs; the CLI lookup is cached per process,
// so PATH and the reported-models file are set before agents.js loads.
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-catalog-refresh-'));
const runsFile = path.join(root, 'runs');
const reportedFile = path.join(root, 'reported-models.json');
fs.writeFileSync(
  path.join(root, 'opencode'),
  `#!${process.execPath}
const fs = require('node:fs');
fs.appendFileSync(${JSON.stringify(runsFile)}, 'x');
if (process.env.FAKE_OPENCODE_FAIL) process.exit(1);
setTimeout(() => console.log('acme/fast-model'), 100);
`,
  { mode: 0o755 },
);
process.env.PATH = `${root}${path.delimiter}${process.env.PATH}`;
process.env.RELAY_REPORTED_MODELS_FILE = reportedFile;
process.env.RELAY_MODEL_DISCOVERY = '0';

const { refreshAgentModels } = require('../lib/agents');

const runs = () => (fs.existsSync(runsFile) ? fs.readFileSync(runsFile, 'utf8').length : 0);
const recorded = () => JSON.parse(fs.readFileSync(reportedFile, 'utf8')).opencode;

// The fake is a POSIX script, so Windows cannot execute it.
const skip = process.platform === 'win32';

test('refresh records the CLI catalog, then waits out the ten-minute window', { skip }, async () => {
  await refreshAgentModels('opencode');
  assert.equal(runs(), 1);
  assert.deepEqual(recorded().map((model) => model.id), ['acme/fast-model']);

  await refreshAgentModels('opencode');
  assert.equal(runs(), 1);
});

test('force refreshes inside the window, and concurrent callers share one run', { skip }, async () => {
  await Promise.all([
    refreshAgentModels('opencode', { force: true }),
    refreshAgentModels('opencode', { force: true }),
  ]);
  assert.equal(runs(), 2);
});

test('a failing CLI resolves and keeps the last catalog', { skip }, async () => {
  process.env.FAKE_OPENCODE_FAIL = '1';
  try {
    await refreshAgentModels('opencode', { force: true });
  } finally {
    delete process.env.FAKE_OPENCODE_FAIL;
  }
  assert.equal(runs(), 3);
  assert.deepEqual(recorded().map((model) => model.id), ['acme/fast-model']);
});

test('an agent without a catalog fetcher resolves without running anything', async () => {
  const before = runs();
  await refreshAgentModels('claude', { force: true });
  assert.equal(runs(), before);
});
