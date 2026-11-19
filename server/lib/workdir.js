'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

// Per-device work directory. Each client carries its own current path via the
// `x-workdir` request header, so two devices can work in different paths at the
// same time. This module only validates, resolves, and creates paths; there is
// no shared "current workdir" state anymore. The `.env` RELAY_DEFAULT_DIR is
// kept solely as an optional override for the default a brand-new device starts
// from. Session identity is keyed by workdir + agent + chat session in server.js.
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

// Windows paths compare without case, so `d:\relay` and `D:\Relay` are one place.
function comparable(value) {
  return process.platform === 'win32' ? value.toLowerCase() : value;
}

function isInsideDir(parent, child) {
  const base = comparable(parent);
  const target = comparable(child);
  return target === base || target.startsWith(base.endsWith(path.sep) ? base : `${base}${path.sep}`);
}

// Isolated installs set RELAY_WORKSPACE_ROOT: every work directory, the file
// API and the agents' permission tiers are then confined to that directory.
// Unset means the open mode, where any absolute path can be a workdir. Read on
// each call (no file access) so one process can be tested in both modes. A
// value that is not an absolute path throws instead of silently running open.
function getWorkspaceRoot() {
  const raw = String(process.env.RELAY_WORKSPACE_ROOT || '').trim();
  if (!raw) return null;
  if (!path.isAbsolute(raw)) {
    throw new WorkdirError('RELAY_WORKSPACE_ROOT must be an absolute path', {
      code: 'WORKSPACE_ROOT_INVALID',
      status: 500,
      dir: raw,
    });
  }
  return path.resolve(raw);
}

function outsideWorkspaceError(dir) {
  return new WorkdirError('workdir is outside the isolated workspace', {
    code: 'WORKDIR_OUTSIDE_WORKSPACE',
    status: 403,
    dir,
  });
}

// The deepest existing ancestor decides where a path really is, so a link or
// junction inside the workspace cannot lead a workdir out of it.
function realLocation(dir) {
  let existing = dir;
  while (!fs.existsSync(existing)) {
    const parent = path.dirname(existing);
    if (parent === existing) return dir;
    existing = parent;
  }
  return path.resolve(fs.realpathSync(existing), path.relative(existing, dir));
}

// Throws unless `dir` (already absolute) is inside the workspace root. A no-op
// in open mode. Also the last check before an agent process gets a cwd.
function assertInsideWorkspace(dir) {
  const root = getWorkspaceRoot();
  if (!root) return dir;
  const resolved = path.resolve(dir);
  if (!isInsideDir(root, resolved)) throw outsideWorkspaceError(resolved);
  const realRoot = fs.existsSync(root) ? fs.realpathSync(root) : root;
  if (!isInsideDir(realRoot, realLocation(resolved))) throw outsideWorkspaceError(resolved);
  return dir;
}

function expandWorkdir(value) {
  const raw = String(value || '').trim();
  if (!raw) return path.join(os.homedir(), 'Relay');
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
  return assertInsideWorkspace(resolved);
}

// The path a brand-new device (one that has not chosen a workdir yet) starts
// from. Comes from RELAY_DEFAULT_DIR when set, otherwise ~/Relay. An isolated
// install starts at its workspace root unless RELAY_DEFAULT_DIR is inside it.
function getDefaultWorkdir() {
  const root = getWorkspaceRoot();
  if (root) {
    if (process.env.RELAY_DEFAULT_DIR) {
      try {
        return resolveWorkdir(process.env.RELAY_DEFAULT_DIR);
      } catch (_err) {
        // Outside the workspace: fall back to the root below.
      }
    }
    return root;
  }
  return process.env.RELAY_DEFAULT_DIR
    ? resolveWorkdir(process.env.RELAY_DEFAULT_DIR)
    : resolveWorkdir(expandWorkdir(''));
}

function ensureWorkdirExists(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  return dir;
}

// Clients percent-encode the x-workdir header because header values must be
// ASCII (a path with Chinese characters is otherwise rejected before sending).
// A value that is not valid percent-encoding is used as sent.
function decodeWorkdirHeader(value) {
  const raw = String(value || '').trim();
  try {
    return decodeURIComponent(raw);
  } catch (_err) {
    return raw;
  }
}

// Resolve the workdir for a request: the device's `x-workdir` header when
// present, otherwise the default. The path is created if missing so agent
// execution and file browsing always have a real cwd. Returns the canonical
// absolute path, which is also the basis of the session scope key.
function resolveRequestWorkdir(value) {
  const raw = String(value || '').trim();
  const dir = raw ? resolveWorkdir(raw) : getDefaultWorkdir();
  return ensureWorkdirExists(dir);
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

// Validate a path the user wants to switch to, optionally creating it. Unlike
// the old setWorkdir this persists no global state: the client stores its own
// choice locally and sends it back via the x-workdir header. Returns the
// canonical path so the client can persist exactly what the backend resolved.
function validateWorkdir(value, { create = false } = {}) {
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
  return { dir: info.dir, created };
}

module.exports = {
  decodeWorkdirHeader,
  WorkdirError,
  isInsideDir,
  getWorkspaceRoot,
  assertInsideWorkspace,
  resolveWorkdir,
  getDefaultWorkdir,
  ensureWorkdirExists,
  resolveRequestWorkdir,
  inspectWorkdir,
  validateWorkdir,
  ENV_PATH,
};
