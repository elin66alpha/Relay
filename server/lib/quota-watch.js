'use strict';

const fs = require('fs');
const path = require('path');
const { getClaudeUsage, getCodexUsage } = require('./usage');

const MIN_PREV = 5;
const MIN_DROP = 5;

const SOURCES = [
  {
    key: 'claude',
    label: 'Claude Code',
    async read() {
      const { data } = await getClaudeUsage();
      const block = data.five_hour || {};
      return { utilization: block.utilization, resetsAt: block.resets_at };
    },
  },
  {
    key: 'codex',
    label: 'Codex',
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

  function load() {
    try {
      return JSON.parse(fs.readFileSync(stateFile, 'utf-8'));
    } catch (_err) {
      return {};
    }
  }

  function save(state) {
    fs.writeFileSync(stateFile, JSON.stringify(state), { mode: 0o600 });
  }

  async function check() {
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
          `${source.label} 的 5 小时额度已清零` +
          `（${Math.round(prev)}% -> ${Math.round(current.utilization)}%）。`;
        if (!current.resetsAt) {
          message += '\n发一条消息后才会开始新的 5 小时计时。';
        }
        try {
          await onReset(message, {
            key: source.key,
            label: source.label,
            prev,
            current: current.utilization,
            resetsAt: current.resetsAt,
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
