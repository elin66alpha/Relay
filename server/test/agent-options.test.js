'use strict';

// Pin to the static catalog so the assertions don't depend on a live CLI's
// discovered model list. Must be set before the module is required (the
// discovery module reads this flag at load time).
process.env.RELAY_MODEL_DISCOVERY = '0';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  buildArgs,
  normalizeSettings,
  describeAgent,
  defaultsFor,
} = require('../lib/agent-options');

// --- defaultsFor ------------------------------------------------------------

test('defaultsFor derives the model from the newest catalog entry', () => {
  assert.deepEqual(defaultsFor('claude'), {
    effort: 'high',
    permission: 'acceptEdits',
    model: 'claude-opus-4-8',
  });
});

test('defaultsFor derives the agy model from its catalog', () => {
  assert.deepEqual(defaultsFor('agy'), {
    model: 'gemini-3-5-flash-medium',
    permission: 'sandbox',
  });
});

// --- buildArgs --------------------------------------------------------------

test('buildArgs emits model, effort, permission in a stable order from defaults', () => {
  assert.deepEqual(buildArgs('claude', {}), [
    '--model', 'claude-opus-4-8',
    '--effort', 'high',
    '--permission-mode', 'acceptEdits',
  ]);
});

test('buildArgs maps explicit valid selections to their flags', () => {
  assert.deepEqual(
    buildArgs('claude', {
      model: 'claude-sonnet-4-6',
      effort: 'low',
      permission: 'plan',
    }),
    [
      '--model', 'claude-sonnet-4-6',
      '--effort', 'low',
      '--permission-mode', 'plan',
    ],
  );
});

test('buildArgs falls back to defaults for forged/unknown option ids (no arg injection)', () => {
  const args = buildArgs('claude', {
    model: '; rm -rf /',
    effort: '$(whoami)',
    permission: '--dangerously-skip-permissions',
  });
  // None of the attacker-controlled strings make it into argv.
  for (const token of args) {
    assert.ok(
      !['; rm -rf /', '$(whoami)', '--dangerously-skip-permissions'].includes(
        token,
      ),
      `unexpected forged token: ${token}`,
    );
  }
  // It degrades to the safe defaults instead.
  assert.deepEqual(args, [
    '--model', 'claude-opus-4-8',
    '--effort', 'high',
    '--permission-mode', 'acceptEdits',
  ]);
});

test('buildArgs maps agy model and permission to its CLI flags', () => {
  assert.deepEqual(buildArgs('agy', {}), [
    '--model', 'Gemini 3.5 Flash (Medium)',
    '--sandbox',
  ]);
});

test('buildArgs maps opencode model/effort/permission to its CLI flags', () => {
  // Default: model from the catalog + bypass permission (effort is opt-in).
  assert.deepEqual(buildArgs('opencode', {}), [
    '-m', 'opencode/big-pickle',
    '--dangerously-skip-permissions',
  ]);
  // Explicit effort (--variant) and the "ask" permission tier (no flag).
  assert.deepEqual(
    buildArgs('opencode', {
      model: 'opencode/deepseek-v4-flash-free',
      effort: 'high',
      permission: 'ask',
    }),
    ['-m', 'opencode/deepseek-v4-flash-free', '--variant', 'high'],
  );
});

test('buildArgs maps hermes permission to --yolo (model from config)', () => {
  // No model picker (uses hermes config default); yolo is the default tier.
  assert.deepEqual(buildArgs('hermes', {}), ['--yolo']);
  assert.deepEqual(buildArgs('hermes', { permission: 'cautious' }), []);
});

test('buildArgs returns [] for an unknown agent', () => {
  assert.deepEqual(buildArgs('nope', { permission: 'bypass' }), []);
});

// --- normalizeSettings ------------------------------------------------------

test('normalizeSettings keeps valid ids and repairs invalid ones to defaults', () => {
  assert.deepEqual(
    normalizeSettings('claude', { model: 'bogus', effort: 'low', permission: 'plan' }),
    { model: 'claude-opus-4-8', effort: 'low', permission: 'plan' },
  );
});

test('normalizeSettings keeps agy model and drops unsupported effort', () => {
  const out = normalizeSettings('agy', { model: 'whatever', permission: 'sandbox' });
  assert.equal(out.model, 'gemini-3-5-flash-medium');
  assert.equal('effort' in out, false);
  assert.equal(out.permission, 'sandbox');
});

// --- describeAgent ----------------------------------------------------------

test('describeAgent advertises supported groups and strips internal args', () => {
  const claude = describeAgent('claude');
  assert.deepEqual(claude.supports, { model: true, effort: true, permission: true });
  // The public catalog never leaks the internal argv tokens.
  for (const group of ['model', 'effort', 'permission']) {
    for (const option of claude[group]) {
      assert.equal('args' in option, false, `${group} option leaked args`);
      assert.ok(typeof option.id === 'string' && option.id.length > 0);
    }
  }

  const agy = describeAgent('agy');
  assert.deepEqual(agy.supports, { model: true, effort: false, permission: true });
});
