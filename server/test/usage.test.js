'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  buildUsageReport,
  cursorUsageFromBodies,
  agyUsageFromBody,
  agyQuotaLogNames,
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
});

test('Antigravity quota discovers ACP worker logs as well as interactive CLI logs', () => {
  assert.deepEqual(agyQuotaLogNames(['cli-20261106_010000.log',
    'acp-worker-20261106_020000-42.log', 'acp-front-20261106_030000-41.log', 'other.log']),
  ['acp-worker-20261106_020000-42.log', 'cli-20261106_010000.log']);
});
