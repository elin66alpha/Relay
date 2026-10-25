'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const discoveryPath = require.resolve('../lib/model-discovery');
require.cache[discoveryPath] = {
  id: discoveryPath,
  filename: discoveryPath,
  loaded: true,
  exports: {
    discoverModels(agentKey) {
      // The shape parseCursorCatalog produces.
      if (agentKey === 'cursor') {
        return [
          { id: 'default', label: 'Auto' },
          {
            id: 'grok-4.7',
            label: 'Grok 4.7',
            effortOption: 'reasoning_effort',
            efforts: [
              { id: 'low', label: 'Low' },
              { id: 'high', label: 'High' },
            ],
            defaultEffort: 'high',
            fast: true,
          },
          { id: 'claude-opus-4-5', label: 'Claude Opus 4.5' },
        ];
      }
      if (agentKey !== 'codex') return null;
      return [
        {
          id: 'gpt-next-sol',
          label: 'GPT Next Sol',
          description: 'Frontier model',
          defaultEffort: 'low',
          efforts: [
            {
              id: 'low',
              label: 'Low',
            },
            {
              id: 'medium',
              label: 'Medium',
            },
            {
              id: 'ultra',
              label: 'Ultra',
            },
          ],
        },
        {
          id: 'gpt-next-luna',
          label: 'GPT Next Luna',
          defaultEffort: 'medium',
          efforts: [
            {
              id: 'low',
              label: 'Low',
            },
            {
              id: 'medium',
              label: 'Medium',
            },
            {
              id: 'high',
              label: 'High',
            },
          ],
        },
        {
          id: 'gpt-no-reasoning',
          label: 'GPT No Reasoning',
          efforts: [],
        },
      ];
    },
  },
};

const {
  acpSessionOptions,
  codexSessionOptions,
  describeAgent,
  normalizeSettings,
} = require('../lib/agent-options');

test('Cursor composes model, effort and fast into ordered config options', () => {
  const catalog = describeAgent('cursor');
  assert.deepEqual(catalog.defaults, { model: 'default', permission: 'bypass', fast: 'off' });
  assert.deepEqual(catalog.effortByModel['grok-4.7'].map((effort) => effort.id), ['low', 'high']);
  assert.equal(catalog.defaultEffortByModel['grok-4.7'], 'high');
  assert.equal(catalog.supports.effort, true);
  assert.equal(catalog.supports.fast, true);
  assert.equal(catalog.model.some((model) => 'effortOption' in model), false, 'kept server-side');
  assert.deepEqual(acpSessionOptions('cursor', {}).configOptions, [['model', 'default']]);
  assert.deepEqual(
    acpSessionOptions('cursor', { model: 'grok-4.7', effort: 'low', fast: 'on' }).configOptions,
    [['model', 'grok-4.7'], ['reasoning_effort', 'low'], ['fast', 'true']],
  );
  // The model's own default effort, and fast stays explicitly off.
  assert.deepEqual(acpSessionOptions('cursor', { model: 'grok-4.7' }).configOptions, [
    ['model', 'grok-4.7'],
    ['reasoning_effort', 'high'],
    ['fast', 'false'],
  ]);
  // A model without parameters gets only the model, whatever was chosen.
  assert.deepEqual(
    acpSessionOptions('cursor', { model: 'claude-opus-4-5', effort: 'low', fast: 'on' }).configOptions,
    [['model', 'claude-opus-4-5']],
  );
});

test('Codex defaults come from the discovered model catalog', () => {
  assert.deepEqual(describeAgent('codex').defaults, {
    effort: 'low',
    permission: 'workspace-write',
    fast: 'off',
    model: 'gpt-next-sol',
  });

  const catalog = describeAgent('codex');
  assert.deepEqual(catalog.model.map((model) => model.id), [
    'gpt-next-sol',
    'gpt-next-luna',
    'gpt-no-reasoning',
  ]);
  assert.deepEqual(catalog.effort.map((effort) => effort.id), [
    'low',
    'medium',
    'ultra',
  ]);
  assert.deepEqual(
    catalog.effortByModel['gpt-next-luna'].map((effort) => effort.id),
    ['low', 'medium', 'high'],
  );
  assert.deepEqual(catalog.defaultEffortByModel, {
    'gpt-next-sol': 'low',
    'gpt-next-luna': 'medium',
  });
  assert.deepEqual(catalog.effortByModel['gpt-no-reasoning'], []);
});

test('Codex validates effort against the selected model', () => {
  assert.deepEqual(
    normalizeSettings('codex', {
      model: 'gpt-next-luna',
      effort: 'ultra',
      permission: 'workspace-write',
    }),
    {
      model: 'gpt-next-luna',
      effort: 'medium',
      permission: 'workspace-write',
      fast: 'off',
    },
  );
  assert.equal(
    codexSessionOptions({ model: 'gpt-next-sol', effort: 'ultra' }).effort,
    'ultra',
  );
});

test('Codex repairs removed models to the catalog default', () => {
  const settings = normalizeSettings('codex', {
    model: 'gpt-removed',
    effort: 'high',
    permission: 'workspace-write',
  });
  assert.deepEqual(settings, {
    model: 'gpt-next-sol',
    effort: 'low',
    permission: 'workspace-write',
    fast: 'off',
  });
});

test('Codex does not add an effort for a model that explicitly has none', () => {
  const settings = normalizeSettings('codex', {
    model: 'gpt-no-reasoning',
    effort: 'ultra',
    permission: 'workspace-write',
  });
  assert.deepEqual(settings, {
    model: 'gpt-no-reasoning',
    permission: 'workspace-write',
    fast: 'off',
  });
});
