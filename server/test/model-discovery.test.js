'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const { parseCodexCatalog } = require('../lib/model-discovery');

test('parseCodexCatalog keeps visible models and their ordered effort metadata', () => {
  const models = parseCodexCatalog({
    models: [
      {
        slug: 'gpt-next-lite',
        display_name: 'GPT Next Lite',
        description: 'Fast model',
        visibility: 'list',
        supported_in_api: true,
        priority: 20,
        default_reasoning_level: 'medium',
        supported_reasoning_levels: [
          { effort: 'low', description: 'Fast' },
          { effort: 'medium', description: 'Balanced' },
        ],
      },
      {
        slug: 'gpt-next',
        display_name: 'GPT Next',
        description: 'Frontier model',
        visibility: 'list',
        supported_in_api: true,
        priority: 1,
        default_reasoning_level: 'low',
        supported_reasoning_levels: [
          { effort: 'low', description: 'Fast' },
          { effort: 'xhigh', description: 'Deep' },
          { effort: 'ultra', description: 'Delegates automatically' },
        ],
      },
      {
        slug: 'internal-review',
        display_name: 'Internal Review',
        visibility: 'hide',
        priority: 0,
        supported_reasoning_levels: [{ effort: 'high' }],
      },
    ],
  });

  assert.deepEqual(
    models.map((model) => model.id),
    ['gpt-next', 'gpt-next-lite'],
  );
  assert.deepEqual(models[0], {
    id: 'gpt-next',
    label: 'GPT Next',
    description: 'Frontier model',
    args: ['-m', 'gpt-next'],
    efforts: [
      {
        id: 'low',
        label: 'Low',
        description: 'Fast',
        args: ['-c', 'model_reasoning_effort=low'],
      },
      {
        id: 'xhigh',
        label: 'Extra high',
        description: 'Deep',
        args: ['-c', 'model_reasoning_effort=xhigh'],
      },
      {
        id: 'ultra',
        label: 'Ultra',
        description: 'Delegates automatically',
        args: ['-c', 'model_reasoning_effort=ultra'],
      },
    ],
    defaultEffort: 'low',
  });
});

test('parseCodexCatalog accepts app-server model/list field names', () => {
  const models = parseCodexCatalog({
    data: [
      {
        id: 'catalog-id',
        model: 'gpt-app-server',
        displayName: 'GPT App Server',
        description: 'From model/list',
        hidden: false,
        isDefault: true,
        defaultReasoningEffort: 'max',
        supportedReasoningEfforts: [
          { reasoningEffort: 'high', description: 'Deep' },
          { reasoningEffort: 'max', description: 'Deepest' },
        ],
      },
    ],
  });

  assert.equal(models[0].id, 'catalog-id');
  assert.deepEqual(models[0].args, ['-m', 'gpt-app-server']);
  assert.equal(models[0].defaultEffort, 'max');
  assert.deepEqual(
    models[0].efforts.map((effort) => effort.id),
    ['high', 'max'],
  );
});

test('parseCodexCatalog rejects malformed, hidden, duplicate, and unsafe entries', () => {
  assert.deepEqual(parseCodexCatalog('{not json'), []);
  const models = parseCodexCatalog({
    models: [
      { slug: 'safe', visibility: 'list', supported_reasoning_levels: [] },
      { slug: 'safe', visibility: 'list', supported_reasoning_levels: [] },
      { slug: '--model', visibility: 'list', supported_reasoning_levels: [] },
      {
        slug: 'no-api',
        visibility: 'list',
        supported_in_api: false,
        supported_reasoning_levels: [],
      },
      {
        slug: 'safe-two',
        visibility: 'list',
        default_reasoning_level: 'forged effort',
        supported_reasoning_levels: [
          { effort: 'medium' },
          { effort: 'medium' },
          { effort: 'bad effort' },
        ],
      },
    ],
  });

  assert.deepEqual(models.map((model) => model.id), [
    'safe',
    'no-api',
    'safe-two',
  ]);
  assert.deepEqual(
    models[2].efforts.map((effort) => effort.id),
    ['medium'],
  );
  assert.equal(models[2].defaultEffort, 'medium');
});
