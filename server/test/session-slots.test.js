'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { setTimeout: delay } = require('node:timers/promises');
const { createSessionSlots } = require('../lib/session-slots');

function makeSlots(t, options = {}) {
  const live = new Map();
  const closed = [];
  const slots = createSessionSlots({
    live,
    maxLive: 1,
    idleMs: 20,
    async closeEntry(entry) {
      entry.closed = true;
      slots.clearIdleTimer(entry);
      live.delete(entry.key);
      closed.push(entry.key);
      slots.releaseSlot();
    },
    ...options,
  });
  t.after(() => {
    for (const entry of live.values()) slots.clearIdleTimer(entry);
  });
  function add(key, extra = {}) {
    const entry = { key, lastActivity: 0, turn: null, closed: false, ...extra };
    live.set(key, entry);
    return entry;
  }
  return { slots, live, closed, add };
}

test('the cap evicts the least recently active idle session, not a running turn', async (t) => {
  const { slots, live, closed, add } = makeSlots(t, { maxLive: 3 });
  add('running', { turn: {}, lastActivity: 0 });
  add('recent', { lastActivity: 20 });
  add('old', { lastActivity: 10 });
  await slots.acquireSlot();
  add('new');
  assert.deepEqual(closed, ['old']);
  assert.equal(live.size, 3);
  assert.equal(slots.waiting, 0);
});

test('a capped caller waits until a turn ends and makes a session evictable', async (t) => {
  const { slots, live, closed, add } = makeSlots(t);
  const entry = add('busy', { turn: {} });
  let acquired = false;
  const pending = slots.acquireSlot().then(() => { acquired = true; });
  await Promise.resolve();
  assert.equal(acquired, false);
  assert.equal(slots.waiting, 1);
  assert.equal(live.size, 1);
  entry.turn = null;
  slots.pumpWaiters();
  await pending;
  assert.deepEqual(closed, ['busy']);
  assert.equal(slots.waiting, 0);
});

test('releasing a removed session wakes a capped caller', async (t) => {
  const { slots, live, add } = makeSlots(t);
  add('busy', { turn: {} });
  const pending = slots.acquireSlot();
  assert.equal(slots.waiting, 1);
  live.delete('busy');
  slots.releaseSlot();
  await pending;
  assert.equal(slots.waiting, 0);
});

test('pool policy protects background turns and orders eviction candidates', async (t) => {
  const { slots, live, closed, add } = makeSlots(t, {
    maxLive: 3,
    isBusy: (entry) => entry.turn || entry.background,
    evictsBefore: (a, b) => a.tasks !== b.tasks
      ? !a.tasks
      : a.lastActivity < b.lastActivity,
  });
  add('background-turn', { background: {}, tasks: false, lastActivity: 0 });
  add('background-task', { tasks: true, lastActivity: 1 });
  add('idle', { tasks: false, lastActivity: 2 });
  await slots.acquireSlot();
  assert.deepEqual(closed, ['idle']);
  add('new', { turn: {} });
  await slots.acquireSlot();
  assert.deepEqual(closed, ['idle', 'background-task']);
  assert.equal(live.has('background-turn'), true);
});

test('clearing an idle timer keeps the session; rescheduling closes it', async (t) => {
  const { slots, closed, add } = makeSlots(t);
  const entry = add('idle');
  slots.scheduleIdleClose(entry);
  slots.clearIdleTimer(entry);
  await delay(60);
  assert.deepEqual(closed, []);
  slots.scheduleIdleClose(entry);
  await delay(60);
  assert.deepEqual(closed, ['idle']);
  slots.scheduleIdleClose(entry);
  await delay(60);
  assert.deepEqual(closed, ['idle'], 'a closed session is never closed twice');
});

test('idle timers leave active turns alone and retry while background tasks run', async (t) => {
  const { slots, closed, add } = makeSlots(t, {
    isBusy: (entry) => entry.turn || entry.background,
    keepAlive: (entry) => entry.tasks > 0,
  });
  const turn = add('turn', { turn: {} });
  const background = add('background', { background: {} });
  const task = add('task', { tasks: 1 });
  for (const entry of [turn, background, task]) slots.scheduleIdleClose(entry);
  await delay(60);
  assert.deepEqual(closed, []);
  task.tasks = 0;
  await delay(60);
  assert.deepEqual(closed, ['task']);
  turn.turn = null;
  background.background = null;
  slots.scheduleIdleClose(turn);
  slots.scheduleIdleClose(background);
  await delay(60);
  assert.deepEqual(closed, ['task', 'turn', 'background']);
});

test('always-on sessions are never idle-closed until unmarked', async (t) => {
  const pinned = new Set(['pinned']);
  const { slots, closed, add } = makeSlots(t, {
    idleMs: 20,
    isAlwaysOn: (key) => pinned.has(key),
  });
  const entry = add('pinned');
  slots.scheduleIdleClose(entry);
  await delay(70);
  assert.deepEqual(closed, []);
  pinned.delete('pinned');
  await delay(60);
  assert.deepEqual(closed, ['pinned']);
});

test('always-on sessions are never evicted by LRU and do not count toward maxLive', async (t) => {
  const pinned = new Set(['p1', 'p2']);
  const { slots, live, closed, add } = makeSlots(t, {
    maxLive: 2,
    isAlwaysOn: (key) => pinned.has(key),
  });
  // Two always-on entries plus one ordinary entry: ordinary count is 1 (< 2).
  add('p1', { lastActivity: 0 });
  add('p2', { lastActivity: 1 });
  add('o1', { lastActivity: 10 });
  await slots.acquireSlot('o2');
  add('o2', { lastActivity: 20 });
  assert.deepEqual(closed, [], 'ordinary sessions get their full cap of 2');
  assert.equal(live.size, 4);

  // Acquiring a 3rd ordinary session evicts o1 (the oldest ordinary), never p1/p2.
  await slots.acquireSlot('o3');
  add('o3', { lastActivity: 30 });
  assert.deepEqual(closed, ['o1']);
  assert.equal(live.has('p1'), true);
  assert.equal(live.has('p2'), true);
  assert.equal(live.size, 4);
});

test('acquiring an always-on key does not wait even when the ordinary cap is full and busy', async (t) => {
  const pinned = new Set(['p1']);
  const { slots, live, closed, add } = makeSlots(t, {
    maxLive: 1,
    isAlwaysOn: (key) => pinned.has(key),
  });
  add('busy-ordinary', { turn: {} });
  let acquired = false;
  await slots.acquireSlot('p1').then(() => {
    acquired = true;
  });
  assert.equal(acquired, true);
  assert.equal(slots.waiting, 0);
  assert.deepEqual(closed, []);
  assert.equal(live.has('busy-ordinary'), true);
});
