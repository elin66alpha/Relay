'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const { getAgentStatuses } = require('./agent-status');
const { executableInPath, locateBin } = require('./cli-paths');
const { listTokenSummaries, hasConfiguredToken } = require('./tokens');
const { inspectWorkdir } = require('./workdir');

const SERVER_DIR = path.join(__dirname, '..');
const REPO_DIR = path.join(SERVER_DIR, '..');

function authStatus(agentKey) {
  const status = getAgentStatuses()[agentKey];
  return status ? status.authed === true : null;
}

function safeStat(filePath) {
  try {
    return fs.statSync(filePath);
  } catch (_err) {
    return null;
  }
}

function accessFlag(filePath, mode) {
  try {
    fs.accessSync(filePath, mode);
    return true;
  } catch (_err) {
    return false;
  }
}

function storageFile(name, filePath) {
  const stat = safeStat(filePath);
  const target = stat ? filePath : path.dirname(filePath);
  return {
    name,
    file: path.relative(SERVER_DIR, filePath) || path.basename(filePath),
    exists: Boolean(stat),
    readable: stat ? accessFlag(filePath, fs.constants.R_OK) : false,
    writable: accessFlag(target, fs.constants.W_OK),
    sizeBytes: stat && stat.isFile() ? stat.size : null,
    modifiedAt: stat ? stat.mtime.toISOString() : null,
  };
}

// The same lookup the runner uses, so a CLI found only in a per-user fallback
// dir is reported where it actually runs from.
function findCommand(command) {
  const found = executableInPath(command) || locateBin(command);
  return { command, available: Boolean(found), path: found || '' };
}

function inspectWorkdirSafe(value) {
  try {
    const info = inspectWorkdir(value);
    const stat = safeStat(info.dir);
    return {
      ...info,
      readable: info.exists ? accessFlag(info.dir, fs.constants.R_OK) : false,
      writable: info.exists ? accessFlag(info.dir, fs.constants.W_OK) : false,
      modifiedAt: stat ? stat.mtime.toISOString() : null,
    };
  } catch (err) {
    return {
      dir: String(value || ''),
      exists: false,
      isDirectory: false,
      readable: false,
      writable: false,
      error: err.message,
      code: err.code,
    };
  }
}

function tokenStats() {
  const tokens = listTokenSummaries();
  const active = tokens.filter((token) => !token.revoked).length;
  return {
    configured: hasConfiguredToken(),
    total: tokens.length,
    active,
    revoked: tokens.length - active,
  };
}

function packageVersion() {
  try {
    const pkg = JSON.parse(
      fs.readFileSync(path.join(SERVER_DIR, 'package.json'), 'utf8'),
    );
    return String(pkg.version || '');
  } catch (_err) {
    return '';
  }
}

function buildDiagnostics({
  workdir,
  defaultWorkdir,
  publicBaseUrl,
  host,
  port,
  quotaWatch,
  agentTimeoutMs,
  maxUploadBytes,
  maxDownloadBytes,
  webBuildDir,
  agents,
  runtime,
}) {
  const webIndex = path.join(webBuildDir, 'index.html');
  return {
    ok: true,
    createdAt: new Date().toISOString(),
    server: {
      version: packageVersion(),
      node: process.version,
      platform: process.platform,
      arch: process.arch,
      pid: process.pid,
      hostname: os.hostname(),
      cwd: process.cwd(),
      serverDir: SERVER_DIR,
      repoDir: REPO_DIR,
      host,
      port,
      publicBaseUrl,
      quotaWatch,
      agentTimeoutMs,
      maxUploadBytes,
      maxDownloadBytes,
      webBuild: {
        dir: webBuildDir,
        indexExists: fs.existsSync(webIndex),
      },
    },
    runtime: {
      sseClients: runtime.sseClients,
      activeRequests: runtime.activeRequests,
      runningScopes: runtime.runningScopes,
      queuedScopes: runtime.queuedScopes,
    },
    auth: tokenStats(),
    workdir: {
      current: inspectWorkdirSafe(workdir),
      default: inspectWorkdirSafe(defaultWorkdir),
    },
    agents: agents.map((agent) => ({
      key: agent.key,
      label: agent.label,
      description: agent.description,
      cli: findCommand(agent.bin || agent.key),
      loggedIn: authStatus(agent.key),
    })),
    storage: [
      storageFile('tokens', path.join(SERVER_DIR, 'tokens.json')),
      storageFile('agent sessions', path.join(SERVER_DIR, 'agent-sessions.json')),
      storageFile('chat sessions', path.join(SERVER_DIR, 'chat-sessions.json')),
      storageFile('chat history', path.join(SERVER_DIR, 'chat-history.json')),
      storageFile('quota schedules', path.join(SERVER_DIR, 'quota-schedules.json')),
    ],
  };
}

module.exports = { buildDiagnostics };

