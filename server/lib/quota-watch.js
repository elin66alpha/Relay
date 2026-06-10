'use strict';

const path = require('path');
const { createJsonStore } = require('./json-store');
const { getClaudeUsage, getCodexUsage } = require('./usage');

const MIN_PREV = 5;
const MIN_DROP = 5;

const SOURCES = [
  {
    key: 'claude',
    label: 'Claude Code',
    labelZh: 'Claude Code',
    async read() {
      const { data } = await getClaudeUsage();
      const block = data.five_hour || {};
      return { utilization: block.utilization, resetsAt: block.resets_at };
    },
  },
  {
    key: 'codex',
    label: 'Codex',
    labelZh: 'Codex',
    async read() {
      const data = await getCodexUsage();
      const block = data.five_hour || {};
      return { utilization: block.utilization, resetsAt: block.resets_at };
    },
  },
];

function startQuotaWatch({ name = 'app', onReset, intervalMs }) {
  const stateFile = path.join(__dirname, '..', `quota-state-${name}.json`);
  const poll = intervalMs || parseInt(process.env.QUOTA_POLL_MS || '300000', 10);
  const store = createJsonStore(stateFile, { defaultValue: {} });

  function load() {
    const state = store.load();
    return state && typeof state === 'object' ? state : {};
  }

  function save(state) {
    store.save(state);
  }

  // Guard against overlapping runs: a slow poll (network hiccups) must not let
  // setInterval stack a second check on top of the first.
  let checking = false;

  async function check() {
    if (checking) return;
    checking = true;
    try {
      await runCheck();
    } finally {
      checking = false;
    }
  }

  async function runCheck() {
    const state = load();
    for (const source of SOURCES) {
      let current;
      try {
        current = await source.read();
      } catch (err) {
        console.error(`[quota:${source.key}] usage query failed: ${err.message}`);
        continue;
      }
      if (current.utilization == null) continue;

      const prev = state[source.key];
      if (
        prev != null &&
        prev >= MIN_PREV &&
        prev - current.utilization >= MIN_DROP
      ) {
        let message =
          `${source.label} 5-hour quota was reset ` +
          `(${Math.round(prev)}% -> ${Math.round(current.utilization)}%).`;
        let messageZh =
          `${source.labelZh} 的 5 小时额度已清零` +
          `（${Math.round(prev)}% -> ${Math.round(current.utilization)}%）。`;
        if (!current.resetsAt) {
          message += '\nThe next 5-hour window starts after sending a message.';
          messageZh += '\n发一条消息后才会开始新的 5 小时计时。';
        }
        try {
          await onReset(message, {
            key: source.key,
            label: source.label,
            labelZh: source.labelZh,
            prev,
            current: current.utilization,
            resetsAt: current.resetsAt,
            messageZh,
          });
          console.log(
            `[quota:${source.key}] reset notification sent ` +
              `(${Math.round(prev)}% -> ${Math.round(current.utilization)}%)`,
          );
        } catch (err) {
          console.error(`[quota:${source.key}] notification failed: ${err.message}`);
        }
      }

      state[source.key] = current.utilization;
    }
    save(state);
  }

  console.log(
    `[quota:${name}] watcher started for Claude + Codex 5h quota, ` +
      `interval ${poll / 1000}s`,
  );
  check();
  return setInterval(check, poll);
}

module.exports = { startQuotaWatch };
