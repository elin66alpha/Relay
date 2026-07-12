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
          args: ['-m', 'gpt-next-sol'],
          defaultEffort: 'low',
          efforts: [
            {
              id: 'low',
              label: 'Low',
              args: ['-c', 'model_reasoning_effort=low'],
            },
            {
              id: 'medium',
              label: 'Medium',
              args: ['-c', 'model_reasoning_effort=medium'],
            },
            {
              id: 'ultra',
              label: 'Ultra',
              args: ['-c', 'model_reasoning_effort=ultra'],
            },
          ],
        },
        {
          id: 'gpt-next-luna',
          label: 'GPT Next Luna',
          args: ['-m', 'gpt-next-luna'],
          defaultEffort: 'medium',
          efforts: [
            {
              id: 'low',
              label: 'Low',
              args: ['-c', 'model_reasoning_effort=low'],
            },
            {
              id: 'medium',
              label: 'Medium',
              args: ['-c', 'model_reasoning_effort=medium'],
            },
            {
              id: 'high',
              label: 'High',
              args: ['-c', 'model_reasoning_effort=high'],
            },
          ],
        },
        {
          id: 'gpt-no-reasoning',
          label: 'GPT No Reasoning',
          args: ['-m', 'gpt-no-reasoning'],
          efforts: [],
        },
      ];
    },
  },
};

const {
  buildArgs,
  defaultsFor,
  describeAgent,
  normalizeSettings,
} = require('../lib/agent-options');

test('Codex defaults come from the discovered model catalog', () => {
  assert.deepEqual(defaultsFor('codex'), {
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
  assert.deepEqual(
    buildArgs('codex', {
      model: 'gpt-next-sol',
      effort: 'ultra',
      permission: 'read-only',
    }),
    [
      '-m',
      'gpt-next-sol',
      '-c',
      'model_reasoning_effort=ultra',
      '-c',
      'sandbox_mode=read-only',
      '-c',
      'approval_policy=never',
      '-c',
      'service_tier="default"',
    ],
  );
});

test('Codex repairs removed models before building argv', () => {
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
  assert.equal(buildArgs('codex', settings)[1], 'gpt-next-sol');
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
  const args = buildArgs('codex', settings);
  assert.equal(args.includes('model_reasoning_effort=ultra'), false);
  assert.equal(args.includes('model_reasoning_effort=medium'), false);
});
