'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  MAX_ALWAYS_ON,
  createAlwaysOnSessions,
} = require('../lib/always-on-sessions');

test('always-on registry caps at 3, allows re-adding an existing key, removes, and lists in insertion order', () => {
  assert.equal(MAX_ALWAYS_ON, 3);
  let tick = 1;
  const registry = createAlwaysOnSessions({
    now: () => `2026-11-23T00:00:0${tick++}Z`,
  });

  assert.equal(registry.has('k1'), false);
  assert.equal(registry.add('k1', { agentKey: 'claude', workdir: '/a', sessionId: 'default' }), true);
  assert.equal(registry.has('k1'), true);
  // Re-adding an existing key is idempotent and does not consume another slot.
  assert.equal(registry.add('k1', { agentKey: 'claude', workdir: '/a', sessionId: 'default' }), true);
  assert.equal(registry.add('k2', { agentKey: 'codex', workdir: '/b', sessionId: 's2' }), true);
  assert.equal(registry.add('k3', { agentKey: 'cursor', workdir: '/c', sessionId: 's3' }), true);
  assert.equal(registry.add('k4', { agentKey: 'opencode', workdir: '/d', sessionId: 's4' }), false);
  assert.equal(registry.has('k4'), false);
  // Re-adding an existing key while full is still ok.
  assert.equal(registry.add('k2', { agentKey: 'codex', workdir: '/b', sessionId: 's2' }), true);

  const listed = registry.list();
  assert.deepEqual(
    listed.map((e) => ({
      key: e.key,
      agentKey: e.agentKey,
      workdir: e.workdir,
      sessionId: e.sessionId,
      since: e.since,
    })),
    [
      { key: 'k1', agentKey: 'claude', workdir: '/a', sessionId: 'default', since: '2026-11-23T00:00:01Z' },
      { key: 'k2', agentKey: 'codex', workdir: '/b', sessionId: 's2', since: '2026-11-23T00:00:02Z' },
      { key: 'k3', agentKey: 'cursor', workdir: '/c', sessionId: 's3', since: '2026-11-23T00:00:03Z' },
    ],
  );
  // Mutating the returned objects does not alter registry state.
  listed[0].workdir = '/mutated';
  assert.equal(registry.list()[0].workdir, '/a');

  assert.equal(registry.remove('k2'), true);
  assert.equal(registry.remove('k2'), false);
  assert.equal(registry.has('k2'), false);
  assert.equal(registry.add('k4', { agentKey: 'opencode', workdir: '/d', sessionId: 's4' }), true);
  assert.deepEqual(
    registry.list().map((e) => e.key),
    ['k1', 'k3', 'k4'],
  );
});
