'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

// 三个 agent 共用的工作目录。实际的 CLI 调用逻辑都在 lib/agents.js，
// 这里只负责确保目录存在并返回路径。
function expandWorkdir(value) {
  const raw = String(value || '').trim();
  if (!raw) return path.join(os.homedir(), 'bots_session');
  if (raw === '~') return os.homedir();
  if (raw.startsWith('~/')) return path.join(os.homedir(), raw.slice(2));
  return raw;
}

const DEFAULT_WORKDIR = expandWorkdir(process.env.BOTS_SESSION_DIR);

function ensureWorkdir() {
  if (!fs.existsSync(DEFAULT_WORKDIR)) {
    fs.mkdirSync(DEFAULT_WORKDIR, { recursive: true });
  }
  return DEFAULT_WORKDIR;
}

function getWorkdir() {
  return ensureWorkdir();
}

module.exports = {
  getWorkdir,
  ensureWorkdir,
  DEFAULT_WORKDIR,
};
