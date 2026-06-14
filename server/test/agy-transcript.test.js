'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const { agyReplyFromTranscript } = require('../lib/agents');

function line(obj) {
  return JSON.stringify(obj);
}

test('agy transcript parsing returns the reply after the current prompt', () => {
  const lines = [
    line({
      source: 'USER_EXPLICIT',
      type: 'USER_INPUT',
      content: 'old prompt',
    }),
    line({
      source: 'MODEL',
      type: 'PLANNER_RESPONSE',
      content: 'old answer',
    }),
    line({
      source: 'USER_EXPLICIT',
      type: 'USER_INPUT',
      content: 'current prompt',
    }),
    line({
      source: 'MODEL',
      type: 'PLANNER_RESPONSE',
      tool_calls: [{ name: 'LIST_DIRECTORY' }],
    }),
    line({
      source: 'MODEL',
      type: 'PLANNER_RESPONSE',
      content: 'current answer',
    }),
  ];

  assert.equal(agyReplyFromTranscript(lines, 'current prompt'), 'current answer');
});

test('agy transcript parsing does not return stale replies for a missing prompt', () => {
  const lines = [
    line({
      source: 'USER_EXPLICIT',
      type: 'USER_INPUT',
      content: 'old prompt',
    }),
    line({
      source: 'MODEL',
      type: 'PLANNER_RESPONSE',
      content: 'old answer',
    }),
  ];

  assert.equal(agyReplyFromTranscript(lines, 'current prompt'), '');
});

test('agy transcript parsing falls back when the current prompt has no text reply', () => {
  const lines = [
    line({
      source: 'USER_EXPLICIT',
      type: 'USER_INPUT',
      content: 'old prompt',
    }),
    line({
      source: 'MODEL',
      type: 'PLANNER_RESPONSE',
      content: 'old answer',
    }),
    line({
      source: 'USER_EXPLICIT',
      type: 'USER_INPUT',
      content: 'current prompt',
    }),
    line({
      source: 'MODEL',
      type: 'PLANNER_RESPONSE',
      tool_calls: [{ name: 'GREP_SEARCH' }],
    }),
  ];

  assert.equal(agyReplyFromTranscript(lines, 'current prompt'), '');
});

test('agy transcript parsing uses the latest matching user input', () => {
  const lines = [
    line({
      source: 'USER_EXPLICIT',
      type: 'USER_INPUT',
      content: 'repeat',
    }),
    line({
      source: 'MODEL',
      type: 'PLANNER_RESPONSE',
      content: 'first answer',
    }),
    line({
      source: 'USER_EXPLICIT',
      type: 'USER_INPUT',
      content: 'repeat',
    }),
    line({
      source: 'MODEL',
      type: 'PLANNER_RESPONSE',
      content: 'second answer',
    }),
  ];

  assert.equal(agyReplyFromTranscript(lines, 'repeat'), 'second answer');
});
