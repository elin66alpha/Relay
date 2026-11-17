'use strict';

// Updating the backend itself: the same in-place upgrade the host commands do
// (install.sh on Linux and macOS, update.ps1 on Windows), started from the API.

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.join(__dirname, '..', '..');
const INSTALL_URL =
  'https://github.com/elin66alpha/Relay/releases/latest/download/install.sh';
// The updater restarts the backend, so a second request would only race it.
const RUNNING_MS = 10 * 60 * 1000;

const backendVersion = require('../package.json').version;
const updateLog = path.join(os.tmpdir(), 'relay-update.log');

let startedAt = 0;

class UpdateError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// The updater command for a platform. It must outlive this process: restarting
// the backend kills the backend's process tree, so the command hands the work
// to a process whose parent has already exited.
function updateCommand(platform, root, log) {
  if (platform === 'win32') {
    const script = path.join(root, 'scripts', 'install', 'windows', 'update.ps1');
    return {
      file: 'cmd.exe',
      args: [
        // The inner cmd owns the redirection: without a console of its own,
        // PowerShell started directly by `start /b` logs nothing.
        `/d /s /c "start "" /b cmd.exe /d /s /c "powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${script}" > "${log}" 2>&1""`,
      ],
      options: { windowsVerbatimArguments: true },
    };
  }
  return {
    file: 'sh',
    // RELAY_DIR makes install.sh upgrade this installation without a prompt.
    args: ['-c', `(curl -fsSL "${INSTALL_URL}" | bash) > "$RELAY_UPDATE_LOG" 2>&1 &`],
    options: { env: { ...process.env, RELAY_DIR: root, RELAY_UPDATE_LOG: log } },
  };
}

// Starts the update and returns at once; the backend restarts when it is done.
function startBackendUpdate({
  root = ROOT,
  platform = process.platform,
  run = spawn,
  now = Date.now(),
} = {}) {
  // A release install has no .git; unpacking a release over a source checkout
  // would overwrite the working tree.
  if (fs.existsSync(path.join(root, '.git'))) {
    throw new UpdateError(
      'UPDATE_UNSUPPORTED',
      'This backend runs from a source checkout; update it with git.',
    );
  }
  if (now - startedAt < RUNNING_MS) {
    throw new UpdateError('UPDATE_RUNNING', 'An update is already running.');
  }
  const command = updateCommand(platform, root, updateLog);
  const child = run(command.file, command.args, {
    ...command.options,
    cwd: os.tmpdir(),
    detached: true,
    stdio: 'ignore',
    windowsHide: true,
  });
  child.on('error', () => {
    startedAt = 0;
  });
  child.unref();
  startedAt = now;
}

module.exports = {
  UpdateError,
  backendVersion,
  startBackendUpdate,
  updateCommand,
  updateLog,
};
