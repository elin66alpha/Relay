'use strict';

// Pin discovery off so requiring the module never shells out to the `agy`
// binary while building args.
process.env.RELAY_MODEL_DISCOVERY = '0';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const { buildAgyArgs } = require('../lib/agents');

const DEFAULT_MODEL = ['--model', 'Gemini 3.5 Flash (Medium)'];

// The single invariant that the agy reply bug came down to: the prompt must be
// the VALUE of one `--print=` token, never a bare positional that agy ignores
// (and a bare `--print` must never exist, or it would swallow the next flag).
function assertPromptCarriedSafely(args, prompt) {
  // Exactly one --print token, and it is the `=<prompt>` form.
  const printTokens = args.filter((a) => a === '--print' || a.startsWith('--print='));
  assert.deepEqual(printTokens, [`--print=${prompt}`], 'prompt must ride as a single --print=<prompt> token');
  // No bare `--print` (which would consume the following flag as the prompt).
  assert.equal(args.includes('--print'), false, 'no bare --print that could swallow the next flag');
  // It is the last token, so no later flag can be misparsed after it.
  assert.equal(args[args.length - 1], `--print=${prompt}`, 'the --print=<prompt> token must come last');
  // Round-trips: everything after the first '=' is the exact prompt.
  const value = args[args.length - 1].slice('--print='.length);
  assert.equal(value, prompt);
}

test('default turn: prompt is the --print= value, --sandbox stays its own flag', () => {
  const prompt = 'what is 17 plus 25?';
  const args = buildAgyArgs({ settings: {}, cwd: '/repo', conversationId: null, prompt });

  assert.deepEqual(args, [
    ...DEFAULT_MODEL,
    '--sandbox',
    '--add-dir',
    '/repo',
    `--print=${prompt}`,
  ]);
  // The permission flag is intact and was NOT consumed as the prompt.
  assert.ok(args.includes('--sandbox'));
  assertPromptCarriedSafely(args, prompt);
});

test('resume turn: --conversation <id> is present and the prompt still rides --print=', () => {
  const prompt = 'continue please';
  const args = buildAgyArgs({
    settings: {},
    cwd: '/repo',
    conversationId: 'conv-123',
    prompt,
  });

  assert.deepEqual(args, [
    ...DEFAULT_MODEL,
    '--sandbox',
    '--add-dir',
    '/repo',
    '--conversation',
    'conv-123',
    `--print=${prompt}`,
  ]);
  assertPromptCarriedSafely(args, prompt);
});

test('no conversationId: no --conversation flag is added', () => {
  const args = buildAgyArgs({ settings: {}, cwd: '/repo', conversationId: null, prompt: 'hi' });
  assert.equal(args.includes('--conversation'), false);
});

test('a prompt starting with - stays inside the value, never parsed as a flag', () => {
  const prompt = '--help me understand this repo';
  const args = buildAgyArgs({ settings: {}, cwd: '/repo', conversationId: null, prompt });

  // The leading-dash prompt is one token, not a separate --help flag.
  assert.equal(args.includes('--help'), false);
  assertPromptCarriedSafely(args, prompt);
});

test('prompts with spaces, newlines, and = are preserved verbatim', () => {
  const prompt = 'line one\nset x = 1 && echo "done"';
  const args = buildAgyArgs({ settings: {}, cwd: '/repo', conversationId: null, prompt });
  assertPromptCarriedSafely(args, prompt);
});

test('permission setting flows through buildArgs (bypass instead of sandbox)', () => {
  const args = buildAgyArgs({
    settings: { permission: 'bypass' },
    cwd: '/repo',
    conversationId: null,
    prompt: 'go',
  });
  assert.ok(args.includes('--dangerously-skip-permissions'));
  assert.equal(args.includes('--sandbox'), false);
  assert.deepEqual(args.slice(0, 2), DEFAULT_MODEL);
  assertPromptCarriedSafely(args, 'go');
});
