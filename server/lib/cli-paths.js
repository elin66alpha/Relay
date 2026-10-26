'use strict';

// Where the agent CLIs and the Cursor files Relay touches live. A leaf module,
// so path policy (filesystem.js) and status checks can use it without loading
// the process runner.

const fs = require('fs');
const os = require('os');
const path = require('path');

// Some installers (opencode) put the binary in a per-user dir that isn't on the
// server's PATH, so detection scans PATH first, then known fallback locations.
// Results are cached briefly so /api/agents stays fast.
const LOCATE_BIN_TTL_MS = 60 * 1000;
const locateBinCache = new Map();

const BIN_FALLBACKS = {
  opencode: [path.join(os.homedir(), '.opencode', 'bin', 'opencode')],
  hermes: [path.join(os.homedir(), '.local', 'bin', 'hermes')],
  agent: [path.join(os.homedir(), '.local', 'bin', 'agent')],
};

function executableInPath(bin) {
  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const exts =
    process.platform === 'win32'
      ? (process.env.PATHEXT || '.EXE;.CMD;.BAT').split(';')
      : [''];
  for (const dir of dirs) {
    for (const ext of exts) {
      const full = path.join(dir, bin + ext);
      try {
        fs.accessSync(full, fs.constants.X_OK);
        return full;
      } catch (_err) {
        // Keep scanning.
      }
    }
  }
  return null;
}

// `{ full, onPath }`: the binary's absolute path (PATH first, then the
// fallbacks, full null when absent) and whether PATH is where it was found.
function findBin(bin) {
  const cached = locateBinCache.get(bin);
  if (cached && Date.now() - cached.at < LOCATE_BIN_TTL_MS) return cached;
  let full = executableInPath(bin);
  const onPath = full !== null;
  if (!full) {
    for (const candidate of BIN_FALLBACKS[bin] || []) {
      try {
        fs.accessSync(candidate, fs.constants.X_OK);
        full = candidate;
        break;
      } catch (_err) {
        // Try the next candidate.
      }
    }
  }
  const found = { full, onPath, at: Date.now() };
  locateBinCache.set(bin, found);
  return found;
}

// A CLI as something to spawn: the bare name when it is on PATH, so spawn
// resolves it the way a shell would, else the fallback's absolute path.
function locateBin(bin) {
  const { full, onPath } = findBin(bin);
  if (!full) return null;
  return onPath ? bin : full;
}

// A CLI's real file (symlinks followed), for reading or stamping the binary.
function resolveBin(bin) {
  const { full } = findBin(bin);
  if (!full) return null;
  try {
    return fs.realpathSync(full);
  } catch (_err) {
    return null;
  }
}

function commandExists(bin) {
  return findBin(bin).full !== null;
}

// Same locations the Cursor CLI uses for `agent login`.
function cursorAuthFile(
  homeDir = os.homedir(),
  environment = process.env,
  platform = process.platform,
) {
  if (platform === 'win32') {
    const base = environment.APPDATA || path.join(homeDir, 'AppData', 'Roaming');
    return path.join(base, 'Cursor', 'auth.json');
  }
  if (platform === 'darwin') return path.join(homeDir, '.cursor', 'auth.json');
  const base = environment.XDG_CONFIG_HOME || path.join(homeDir, '.config');
  return path.join(base, 'cursor', 'auth.json');
}

// Relay's Cursor runs with a config directory of its own (CURSOR_CONFIG_DIR).
// Cursor writes every model choice into its config as the CLI's default, and
// keeps its ACP sessions there, so a shared directory would change the host
// user's own Cursor setup. Login is separate and stays the host's.
const CURSOR_CONFIG_DIR = process.env.RELAY_CURSOR_CONFIG_DIR
  ? path.resolve(process.env.RELAY_CURSOR_CONFIG_DIR)
  : path.join(__dirname, '..', 'cursor-config');

module.exports = {
  CURSOR_CONFIG_DIR,
  commandExists,
  cursorAuthFile,
  executableInPath,
  locateBin,
  resolveBin,
};
