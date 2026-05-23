'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

// Shared work directory for every CLI agent. Agent execution lives in
// lib/agents.js; this module validates, persists, and creates the path.
const ENV_PATH = path.join(__dirname, '..', '.env');

class WorkdirError extends Error {
  constructor(message, { code, status = 400, dir } = {}) {
    super(message);
    this.name = 'WorkdirError';
    this.code = code;
    this.status = status;
    this.dir = dir;
  }
}

function expandWorkdir(value) {
  const raw = String(value || '').trim();
  if (!raw) return path.join(os.homedir(), 'agent_deck');
  if (raw === '~') return os.homedir();
  if (raw.startsWith('~/')) return path.join(os.homedir(), raw.slice(2));
  return raw;
}

function resolveWorkdir(value) {
  const raw = String(value || '').trim();
  if (!raw) {
    throw new WorkdirError('workdir path is required', {
      code: 'WORKDIR_PATH_REQUIRED',
    });
  }
  const expanded = expandWorkdir(raw);
  if (!path.isAbsolute(expanded)) {
    throw new WorkdirError('workdir must be an absolute path', {
      code: 'WORKDIR_NOT_ABSOLUTE',
      dir: raw,
    });
  }
  const resolved = path.resolve(expanded);
  if (resolved === path.parse(resolved).root) {
    throw new WorkdirError('workdir cannot be the filesystem root', {
      code: 'WORKDIR_ROOT_NOT_ALLOWED',
      dir: resolved,
    });
  }
  return resolved;
}

function readConfiguredWorkdir() {
  return process.env.BOTS_SESSION_DIR
    ? resolveWorkdir(process.env.BOTS_SESSION_DIR)
    : expandWorkdir('');
}

let currentWorkdir = readConfiguredWorkdir();

function ensureWorkdir() {
  if (!fs.existsSync(currentWorkdir)) {
    fs.mkdirSync(currentWorkdir, { recursive: true });
  }
  return currentWorkdir;
}

function getWorkdir() {
  return ensureWorkdir();
}

function inspectWorkdir(value) {
  const dir = resolveWorkdir(value);
  let exists = false;
  let isDirectory = false;
  try {
    const stat = fs.statSync(dir);
    exists = true;
    isDirectory = stat.isDirectory();
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }
  return { dir, exists, isDirectory };
}

function setEnvValue(content, key, value) {
  const escaped = String(value).replace(/\n/g, '');
  const line = `${key}=${escaped}`;
  const re = new RegExp(`^${key}=.*$`, 'm');
  if (re.test(content)) return content.replace(re, line);
  const suffix = content.endsWith('\n') || content.length === 0 ? '' : '\n';
  return `${content}${suffix}${line}\n`;
}

function persistWorkdir(dir) {
  let content = '';
  try {
    content = fs.readFileSync(ENV_PATH, 'utf8');
  } catch (err) {
    if (err.code !== 'ENOENT') throw err;
  }
  fs.writeFileSync(ENV_PATH, setEnvValue(content, 'BOTS_SESSION_DIR', dir));
}

function setWorkdir(value, { create = false } = {}) {
  const info = inspectWorkdir(value);
  if (info.exists && !info.isDirectory) {
    throw new WorkdirError('workdir path exists but is not a directory', {
      code: 'WORKDIR_NOT_DIRECTORY',
      status: 400,
      dir: info.dir,
    });
  }
  let created = false;
  if (!info.exists) {
    if (!create) {
      throw new WorkdirError('workdir path does not exist', {
        code: 'WORKDIR_NOT_FOUND',
        status: 404,
        dir: info.dir,
      });
    }
    fs.mkdirSync(info.dir, { recursive: true });
    created = true;
  }
  persistWorkdir(info.dir);
  process.env.BOTS_SESSION_DIR = info.dir;
  currentWorkdir = info.dir;
  return { dir: currentWorkdir, created };
}

module.exports = {
  getWorkdir,
  ensureWorkdir,
  inspectWorkdir,
  setWorkdir,
  WorkdirError,
};
