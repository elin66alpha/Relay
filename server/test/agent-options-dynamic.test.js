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
  codexSessionOptions,
  describeAgent,
  normalizeSettings,
} = require('../lib/agent-options');

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
