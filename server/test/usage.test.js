'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  buildUsageReport,
  cursorUsageFromBodies,
  agyUsageFromBody,
  agyQuotaLogNames,
  agyContextFromTrajectory,
  fetchAgyUsage,
  readAgyContext,
  markExpiredQuotas,
} = require('../lib/usage');

const NOW = Date.parse('2026-06-19T12:00:00Z');

test('markExpiredQuotas leaves fresh (non-stale) data untouched', () => {
  const quotas = [
    { key: 'five_hour', resetsAt: '2026-06-19T08:00:00Z', expired: false },
  ];
  const out = markExpiredQuotas(quotas, false, NOW);
  assert.equal(out, quotas);
  assert.equal(out[0].expired, false);
});

test('markExpiredQuotas flags stale buckets whose reset has passed', () => {
  const quotas = [
    { key: 'five_hour', resetsAt: '2026-06-19T08:00:00Z', expired: false },
    { key: 'seven_day', resetsAt: '2026-06-24T00:00:00Z', expired: false },
  ];
  const out = markExpiredQuotas(quotas, true, NOW);
  assert.equal(out[0].expired, true); // 08:00 < 12:00 → window already reset
  assert.equal(out[1].expired, false); // future reset → still meaningful
});

test('markExpiredQuotas treats the exact reset moment as expired', () => {
  const quotas = [
    { key: 'five_hour', resetsAt: '2026-06-19T12:00:00Z', expired: false },
  ];
  assert.equal(markExpiredQuotas(quotas, true, NOW)[0].expired, true);
});

test('markExpiredQuotas ignores buckets without a reset time', () => {
  const quotas = [{ key: 'five_hour', resetsAt: null, expired: false }];
  const out = markExpiredQuotas(quotas, true, NOW);
  assert.equal(out[0].expired, false);
});

test('cursorUsageFromBodies reads an xAI Premium weekly pool as remaining percent', () => {
  const usage = cursorUsageFromBodies(
    {
      planInfo: {
        planName: 'Premium',
        includedUsagePeriod: 'INCLUDED_USAGE_PERIOD_WEEKLY',
        includedUsageResetsAt: '1793519407124',
      },
    },
    {
      billingCycleEnd: '1793519407124',
      planUsage: { totalPercentUsed: 20, autoPercentUsed: 20, apiPercentUsed: 0 },
    },
  );
  assert.equal(usage.plan, 'Premium');
  assert.equal(usage.quotas.length, 1);
  assert.equal(usage.quotas[0].key, 'seven_day');
  assert.equal(usage.quotas[0].remainingPercent, 80);
  assert.equal(usage.quotas[0].resetsAt, new Date(1793519407124).toISOString());
});

test('cursorUsageFromBodies keeps legacy Cursor and API pools apart', () => {
  const usage = cursorUsageFromBodies(
    { planInfo: { planName: 'Pro', includedUsagePeriod: 'INCLUDED_USAGE_PERIOD_MONTHLY' } },
    {
      billingCycleEnd: '1789718953000',
      planUsage: { autoPercentUsed: 3.5, apiPercentUsed: 1.25, totalPercentUsed: 4 },
    },
  );
  assert.deepEqual(
    usage.quotas.map((quota) => [quota.key, quota.remainingPercent]),
    [
      ['cursor_models', 96.5],
      ['api_models', 98.75],
    ],
  );
});

test('buildUsageReport rejects an unknown source before querying anything', async () => {
  await assert.rejects(buildUsageReport({ source: 'nope' }), {
    status: 400,
    message: 'Unknown usage source: nope',
  });
});

test('Antigravity keeps every subscription bucket including Argon and real zero remaining', () => {
  const quota = agyUsageFromBody({ response: { groups: [
    { displayName: 'Gemini', buckets: [{ bucketId: 'gemini-5h', remainingFraction: 0, resetTime: '2026-11-07T00:00:00Z' }] },
    { displayName: 'Claude/GPT', buckets: [{ bucketId: '3p-weekly', remainingFraction: 0.75 }] },
    { displayName: 'Argon', buckets: [{ bucketId: 'argon-weekly', remainingFraction: 1 }, { bucketId: 'missing' }] },
  ], accountEmail: 'private@example.invalid' } });
  assert.deepEqual(quota.quotas.map((q) => q.remainingPercent), [0, 75, 100]);
  assert.equal(quota.quotas[0].resetsAt, '2026-11-07T00:00:00.000Z');
  assert.equal(quota.quotas[1].resetsAt, null);
  assert.equal(JSON.stringify(quota).includes('private@'), false);
  assert.throws(() => agyUsageFromBody({}), /no quota buckets/);

  // agy lists the week first; the app reads 5 hours first, and an unknown window keeps its name.
  const ordered = agyUsageFromBody({ groups: [{ name: 'Claude and GPT models', buckets: [
    { id: '3p-weekly', window: 'weekly', remaining_fraction: 0.9 },
    { id: '3p-5h', window: '5h', remaining_fraction: 1 },
    { id: '3p-daily', name: 'Daily Limit', remaining_fraction: 1 },
  ] }] });
  assert.deepEqual(ordered.quotas.map((q) => [q.key, q.label, q.window]), [
    ['3p-5h', 'Claude/GPT', '5h'],
    ['3p-weekly', 'Claude/GPT', 'weekly'],
    ['3p-daily', 'Claude/GPT · Daily Limit', null],
  ]);
});

test('Antigravity quota keeps live ACP workers ahead of any number of newer CLI logs', () => {
  const clis = Array.from({ length: 14 }, (_, i) => `cli-20261106_03${String(i).padStart(2, '0')}00.log`);
  const names = agyQuotaLogNames([...clis, 'acp-worker-20261106_020000-42.log',
    'acp-worker-20261106_025000-43.log', 'acp-front-20261106_030000-41.log', 'other.log'],
  (pid) => pid === 42);
  assert.equal(names[0], 'acp-worker-20261106_020000-42.log');
  assert.equal(names.includes('acp-worker-20261106_025000-43.log'), false);
  assert.equal(names.length, 13);
  assert.equal(names[1], 'cli-20261106_031300.log');
});

test('Antigravity quota parses headless /usage CLI JSON output and falls back when no language server is running', async () => {
  const cliBody = {
    conversation_id: '',
    status: 'SUCCESS',
    response: 'Gemini Models\tWeekly Limit Remaining\t99%\t2026-11-11T09:16:36Z\n',
    command: {
      name: 'usage',
      data: {
        groups: [
          {
            name: 'Gemini Models',
            buckets: [
              { id: 'gemini-5h', name: 'Five Hour Limit Remaining', window: '5h', remaining_fraction: 0.99, reset_time: '2026-11-06T20:20:32Z' },
              { id: 'gemini-weekly', name: 'Weekly Limit Remaining', window: 'weekly', remaining_fraction: 0.95, reset_time: '2026-11-11T09:16:36Z' },
            ],
          },
          {
            name: 'Claude and GPT models',
            buckets: [
              { id: '3p-5h', name: 'Five Hour Limit Remaining', window: '5h', remaining_fraction: 0.88, reset_time: '2026-11-06T19:45:23Z' },
            ],
          },
        ],
        account_email: 'private@example.invalid',
      },
    },
  };
  const parsed = agyUsageFromBody(cliBody);
  assert.deepEqual(
    parsed.quotas.map((q) => [q.key, q.label, q.window, q.remainingPercent]),
    [
      ['gemini-5h', 'Gemini', '5h', 99],
      ['gemini-weekly', 'Gemini', 'weekly', 95],
      ['3p-5h', 'Claude/GPT', '5h', 88],
    ],
  );
  assert.equal(JSON.stringify(parsed).includes('private@'), false);

  let cliCalls = 0;
  const fallback = await fetchAgyUsage({
    readPorts: () => [41001],
    callServer: async () => {
      throw new Error('connection refused');
    },
    runCli: async () => {
      cliCalls += 1;
      return cliBody;
    },
  });
  assert.equal(cliCalls, 1);
  assert.equal(fallback.quotas.length, 3);
});

test('Antigravity context reads the latest step from GetCascadeTrajectory', async () => {
  const trajectoryBody = {
    trajectory: {
      generatorMetadata: [
        {
          chatModel: {
            model: 'MODEL_PLACEHOLDER_M419',
            chatStartMetadata: {
              contextWindowMetadata: {
                estimatedTokensUsed: 10348,
                maxContextTokens: 256000,
              },
            },
          },
        },
        {
          chatModel: {
            model: 'MODEL_PLACEHOLDER_M403',
            chatStartMetadata: {
              contextWindowMetadata: {
                estimatedTokensUsed: 10605,
                maxContextTokens: 840000,
              },
            },
          },
        },
      ],
    },
  };
  const parsed = agyContextFromTrajectory(trajectoryBody);
  assert.deepEqual(parsed, {
    used: 10605,
    size: 840000,
    steps: 2,
    model: 'MODEL_PLACEHOLDER_M403',
  });
  assert.equal(agyContextFromTrajectory({}), null);

  // When two ports have the cascade, picks the worker with the newer turn (more steps).
  const ctx = await readAgyContext('11111111-2222-3333-4444-555555555555', {
    readPorts: () => [40001, 40002],
    callServer: async (port, method) => {
      assert.equal(method, 'GetCascadeTrajectory');
      if (port === 40001) {
        return {
          trajectory: {
            generatorMetadata: [trajectoryBody.trajectory.generatorMetadata[0]],
          },
        };
      }
      return trajectoryBody;
    },
  });
  assert.deepEqual(ctx, { used: 10605, size: 840000 });

  // A cascade no server holds is reported as unknown, never loaded into another process.
  const calls = [];
  const missing = await readAgyContext('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', {
    readPorts: () => [40003],
    callServer: async (port, method) => {
      calls.push([port, method]);
      return { trajectory: { generatorMetadata: [] } };
    },
  });
  assert.deepEqual(calls, [[40003, 'GetCascadeTrajectory']]);
  assert.equal(missing, null);
});
