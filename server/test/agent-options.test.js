'use strict';

// Pin to the static catalog so the assertions don't depend on a live CLI's
// discovered model list. Must be set before the module is required (the
// discovery module reads this flag at load time).
process.env.RELAY_MODEL_DISCOVERY = '0';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const {
  normalizeSettings,
  describeAgent,
  acpSessionOptions,
  claudeSdkOptions,
  codexSessionOptions,
} = require('../lib/agent-options');

test('Codex static fallback keeps effort choices valid for its pinned models', () => {
  assert.deepEqual(describeAgent('codex').defaults, {
    effort: 'medium',
    permission: 'workspace-write',
    fast: 'off',
    model: 'gpt-5.5',
  });
  const codex = describeAgent('codex');
  assert.deepEqual(codex.effort.map((option) => option.id), [
    'low',
    'medium',
    'high',
    'xhigh',
  ]);
  assert.equal(codex.effortByModel['gpt-5.4'].some((option) => option.id === 'minimal'), false);
});

// --- acpSessionOptions ------------------------------------------------------
// opencode and hermes run as persistent ACP sessions, so their settings are
// resolved into protocol values.

test('acpSessionOptions resolves opencode defaults to a model and auto-approval', () => {
  assert.deepEqual(acpSessionOptions('opencode', {}), {
    modelId: 'opencode/big-pickle',
    // opencode has no session mode matching its tiers.
    modeId: null,
    approve: true,
  });
  assert.deepEqual(
    acpSessionOptions('opencode', { model: 'opencode/gone-free', permission: 'ask' }),
    { modelId: 'opencode/big-pickle', modeId: null, approve: false },
    'a model the catalog no longer lists falls back to the default',
  );
});

test('acpSessionOptions maps hermes tiers to session modes', () => {
  // yolo is the default tier: auto-approve, and the matching hermes mode.
  assert.deepEqual(acpSessionOptions('hermes', {}), {
    modelId: null,
    modeId: 'dont_ask',
    approve: true,
  });
  assert.deepEqual(acpSessionOptions('hermes', { permission: 'cautious' }), {
    modelId: null,
    modeId: 'default',
    approve: false,
  });
});

test('cursor defaults to Auto and full auto, and maps tiers to its ACP modes', () => {
  assert.deepEqual(acpSessionOptions('cursor', {}), {
    modelId: null,
    modeId: 'agent',
    approve: true,
    configOptions: [['model', 'default']],
  });
  assert.equal(acpSessionOptions('cursor', { permission: 'plan' }).modeId, 'plan');
  assert.equal(acpSessionOptions('cursor', { permission: 'plan' }).approve, false);
  // An id the catalog does not list (here, an id from an older build) falls back.
  assert.deepEqual(
    normalizeSettings('cursor', { model: 'default[]', permission: 'ask' }),
    { model: 'default', permission: 'ask', fast: 'off' },
  );
});

test('acpSessionOptions translates a pinned hermes model id to ACP form', () => {
  // Hermes has no built-in catalog, so models-extra.json is the only way to
  // pin one — and it is written in the CLI's `provider/model` form.
  const extraFile = path.join(__dirname, '..', 'models-extra.json');
  const had = fs.existsSync(extraFile);
  const backup = had ? fs.readFileSync(extraFile) : null;
  try {
    fs.writeFileSync(
      extraFile,
      JSON.stringify({ hermes: [{ id: 'anthropic/claude-sonnet-4' }] }),
    );
    assert.equal(
      acpSessionOptions('hermes', { model: 'anthropic/claude-sonnet-4' }).modelId,
      'anthropic:claude-sonnet-4',
    );
  } finally {
    if (had) fs.writeFileSync(extraFile, backup);
    else fs.rmSync(extraFile, { force: true });
  }
  // opencode ids are already ACP ids and must not be rewritten.
  assert.equal(
    acpSessionOptions('opencode', { model: 'opencode/big-pickle' }).modelId,
    'opencode/big-pickle',
  );
});

// --- normalizeSettings ------------------------------------------------------

test('normalizeSettings keeps valid ids and repairs invalid ones to defaults', () => {
  assert.deepEqual(
    normalizeSettings('claude', { model: 'bogus', effort: 'low', permission: 'plan' }),
    { model: 'claude-opus-4-8', effort: 'low', permission: 'plan', fast: 'off' },
  );
});

test('normalizeSettings drops groups an agent does not support', () => {
  // Hermes pins its model in host config and has no reasoning-effort flag, so
  // only the permission tier survives normalization.
  const out = normalizeSettings('hermes', {
    model: 'whatever',
    effort: 'high',
    permission: 'yolo',
  });
  assert.equal('model' in out, false);
  assert.equal('effort' in out, false);
  assert.equal(out.permission, 'yolo');
});

// --- describeAgent ----------------------------------------------------------

test('describeAgent advertises supported groups', () => {
  const claude = describeAgent('claude');
  assert.deepEqual(claude.supports, {
    model: true,
    effort: true,
    permission: true,
    fast: true,
  });
  for (const group of ['model', 'effort', 'permission', 'fast']) {
    for (const option of claude[group]) {
      assert.ok(typeof option.id === 'string' && option.id.length > 0);
    }
  }

  const hermes = describeAgent('hermes');
  assert.deepEqual(hermes.supports, {
    model: false,
    effort: false,
    permission: true,
    fast: false,
  });
});

test('fast mode is explicit and limited to Claude Code and Codex', () => {
  assert.equal(claudeSdkOptions({ fast: 'on' }).settings.fastMode, true);
  assert.equal(claudeSdkOptions({ fast: 'off' }).settings.fastMode, false);
  assert.equal(codexSessionOptions({ fast: 'on' }).serviceTier, 'fast');
  assert.equal(codexSessionOptions({ fast: 'off' }).serviceTier, 'default');
  assert.equal(normalizeSettings('opencode', { fast: 'on' }).fast, undefined);
});
