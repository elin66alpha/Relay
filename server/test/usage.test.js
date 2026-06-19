'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const { normalizeAgyQuotaSummary, markExpiredQuotas } = require('../lib/usage');

const SAMPLE_AGY_SUMMARY = {
  response: {
    groups: [
      {
        displayName: 'Gemini Models',
        description: 'Models within this group: Gemini Flash, Gemini Pro',
        buckets: [
          {
            bucketId: 'gemini-weekly',
            displayName: 'Weekly Limit',
            description: 'Refreshes in 1 day, 5 hours.',
            window: 'weekly',
            remainingFraction: 0.89087933,
            resetTime: '2026-06-19T03:26:58Z',
          },
          {
            bucketId: 'gemini-5h',
            displayName: 'Five Hour Limit',
            window: '5h',
            remainingFraction: 0.9260299,
            resetTime: '2026-06-17T23:12:49Z',
          },
        ],
      },
      {
        displayName: 'Claude and GPT models',
        description: 'Models within this group: Claude Opus, Claude Sonnet, GPT-OSS',
        buckets: [
          {
            bucketId: '3p-weekly',
            displayName: 'Weekly Limit',
            window: 'weekly',
            remainingFraction: 1,
            resetTime: '2026-06-24T21:19:41Z',
          },
          {
            bucketId: '3p-5h',
            displayName: 'Five Hour Limit',
            window: '5h',
            remainingFraction: 0.75,
            resetTime: '2026-06-18T02:19:41Z',
          },
        ],
      },
    ],
  },
};

test('normalizeAgyQuotaSummary selects Gemini quota group for Gemini models', () => {
  const out = normalizeAgyQuotaSummary(
    SAMPLE_AGY_SUMMARY,
    'Gemini 3.5 Flash (High)',
  );

  assert.equal(out.plan, 'Gemini Models');
  assert.equal(out.five_hour.resets_at, '2026-06-17T23:12:49.000Z');
  assert.equal(out.seven_day.resets_at, '2026-06-19T03:26:58.000Z');
  assert.equal(Number(out.five_hour.utilization.toFixed(5)), 7.39701);
  assert.equal(Number(out.seven_day.utilization.toFixed(5)), 10.91207);
});

test('normalizeAgyQuotaSummary selects third-party quota group for Claude/GPT models', () => {
  const out = normalizeAgyQuotaSummary(
    SAMPLE_AGY_SUMMARY,
    'Claude Sonnet 4.6 (Thinking)',
  );

  assert.equal(out.plan, 'Claude and GPT models');
  assert.equal(out.five_hour.resets_at, '2026-06-18T02:19:41.000Z');
  assert.equal(out.seven_day.resets_at, '2026-06-24T21:19:41.000Z');
  assert.equal(out.five_hour.utilization, 25);
  assert.equal(out.seven_day.utilization, 0);
});

test('normalizeAgyQuotaSummary rejects missing quota groups', () => {
  assert.throws(
    () => normalizeAgyQuotaSummary({ response: { groups: [] } }, 'Gemini 3.5 Flash (High)'),
    /did not include quota groups/,
  );
});

test('normalizeAgyQuotaSummary prefers compact subscription labels', () => {
  const out = normalizeAgyQuotaSummary(
    {
      response: {
        plan: 'Google AI Pro',
        groups: SAMPLE_AGY_SUMMARY.response.groups,
      },
    },
    'Gemini 3.5 Flash (High)',
  );

  assert.equal(out.plan, 'Pro');
});

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
