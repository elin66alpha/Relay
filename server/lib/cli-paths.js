'use strict';

// Where the agent CLIs and the Cursor files Relay touches live. A leaf module,
// so path policy (filesystem.js) and status checks can use it without loading
// the process runner.

const fs = require('fs');
const os = require('os');
const path = require('path');

// Installers put CLIs in per-user dirs (~/.local/bin for claude, codex, cursor,
// hermes; ~/.opencode/bin) that a PM2 or service PATH often lacks, e.g. one
// saved before the CLI's installer edited the shell profile. Detection scans
// PATH first, then those locations. Results are cached briefly so /api/agents
// stays fast.
const LOCATE_BIN_TTL_MS = 60 * 1000;
const locateBinCache = new Map();

// The file names a bare command may have: on Windows, one per PATHEXT entry.
function executableExtensions() {
  return process.platform === 'win32'
    ? (process.env.PATHEXT || '.EXE;.CMD;.BAT').split(';').filter(Boolean)
    : [''];
}

function binFallbacks(bin) {
  const dirs = [path.join(os.homedir(), '.local', 'bin')];
  if (bin === 'opencode') dirs.push(path.join(os.homedir(), '.opencode', 'bin'));
  const exts = executableExtensions();
  return dirs.flatMap((dir) => exts.map((ext) => path.join(dir, bin + ext)));
}

function executableInPath(bin) {
  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const exts = executableExtensions();
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
    for (const candidate of binFallbacks(bin)) {
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

// What a Windows .cmd/.bat launcher runs, read from its last `%*` line. npm and
// pnpm install CLIs as such launchers, and Node cannot spawn a batch file
// without a shell (ENOENT for the bare name, EINVAL for the path). Returns
// `{ target, node }` (node: the launcher runs target with Node) or null.
function readBatchShim(file) {
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (_err) {
    return null;
  }
  const line = text
    .split(/\r?\n/)
    .reverse()
    .find((l) => l.includes('%*'));
  if (!line) return null;
  const dir = path.dirname(file);
  const targets = [...line.matchAll(/"%~?dp0%?\\?([^"]+)"/g)]
    .map((m) => path.join(dir, m[1]))
    .filter((p) => !/(^|[\\/])node(\.exe)?$/i.test(p));
  const target = targets[targets.length - 1];
  if (!target || !fs.existsSync(target)) return null;
  const node =
    /%_prog%|\bnode(\.exe)?"?\s/i.test(line) || /\.[cm]?js$/i.test(target);
  if (!node && !/\.(exe|com)$/i.test(target)) return null;
  return { target, node };
}

// A CLI as `{ cmd, args }` that child_process can spawn without a shell, or
// null when it is not installed. Every place that runs an agent CLI goes
// through this, so a Windows npm launcher (codex.cmd) works like a binary.
function cliCommand(bin, args = []) {
  const located = locateBin(bin);
  if (!located) return null;
  if (process.platform !== 'win32') return { cmd: located, args };
  const { full } = findBin(bin);
  if (!/\.(cmd|bat)$/i.test(full)) return { cmd: full, args };
  const shim = readBatchShim(full);
  if (!shim) return { cmd: full, args };
  return shim.node
    ? { cmd: process.execPath, args: [shim.target, ...args] }
    : { cmd: shim.target, args };
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

function agyAuthFile(homeDir = os.homedir()) {
  return path.join(homeDir, '.gemini', 'antigravity-cli', 'antigravity-oauth-token');
}

// A shell that runs `pm2 start/restart --update-env` (then `pm2 save`) leaves its
// session in the backend's environment for good, and every agent inherits it.
// agy reads SSH_CONNECTION/SSH_CLIENT/SSH_TTY as an SSH login and keeps its token
// in a file instead of the keyring the host's own agy uses, so it looks logged
// out; ANTIGRAVITY_* claims a tool call of an agy session long gone. Agents run
// as the host. SSH_AUTH_SOCK stays: agents may use it for git over SSH.
function dropLoginSessionEnv(env) {
  for (const key of Object.keys(env)) {
    if (/^(SSH_(CONNECTION|CLIENT|TTY)|ANTIGRAVITY_)/.test(key)) delete env[key];
  }
  return env;
}

module.exports = {
  agyAuthFile,
  dropLoginSessionEnv,
  CURSOR_CONFIG_DIR,
  cliCommand,
  commandExists,
  cursorAuthFile,
  executableInPath,
  locateBin,
  resolveBin,
};
