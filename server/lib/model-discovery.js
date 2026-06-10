'use strict';

// Dynamic model discovery: read the model list each agent CLI actually ships so
// the picker tracks the installed binary instead of a hand-maintained catalog.
// When a CLI updates (e.g. `claude update` adds Fable 5), the new models appear
// here automatically — no code change.
//
// Each strategy returns an array of { id, label, args } (newest first) or null
// when discovery is unavailable; agent-options falls back to its static catalog
// in that case. Results are cached per agent and keyed by the resolved binary's
// path + size + mtime, so an update busts the cache while steady-state calls
// (every chat turn resolves defaults through here) stay a cheap map lookup.
//
// Set RELAY_MODEL_DISCOVERY=0 to disable and always use the static catalog.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const DISABLED =
  process.env.RELAY_MODEL_DISCOVERY === '0' ||
  process.env.RELAY_MODEL_DISCOVERY === 'false';

// agentKey -> { stamp, models }. models is a non-empty array or null; both are
// cached so a missing/empty result never re-spawns on every turn.
const cache = new Map();

// Resolve a command name to its real (symlink-followed) absolute path, or null.
function resolveBinary(command) {
  try {
    const win = process.platform === 'win32';
    const result = spawnSync(win ? 'where' : 'command', win ? [command] : ['-v', command], {
      encoding: 'utf8',
      shell: !win,
      timeout: 3000,
    });
    const line = String(result.stdout || '')
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter(Boolean)[0];
    return line ? fs.realpathSync(line) : null;
  } catch (_err) {
    return null;
  }
}

function fileStamp(filePath) {
  try {
    const s = fs.statSync(filePath);
    return `${filePath}:${s.size}:${s.mtimeMs}`;
  } catch (_err) {
    return null;
  }
}

// Stream a (potentially large, ~250MB) binary in chunks, collecting every match
// of `regex` without loading the whole file into memory. A short tail overlap
// between chunks keeps a token from being missed at a boundary.
function scanFile(filePath, regex) {
  const found = new Set();
  let fd;
  try {
    fd = fs.openSync(filePath, 'r');
    const CHUNK = 1 << 20; // 1 MiB
    const buf = Buffer.allocUnsafe(CHUNK);
    let tail = '';
    let position = 0;
    let bytesRead;
    while ((bytesRead = fs.readSync(fd, buf, 0, CHUNK, position)) > 0) {
      position += bytesRead;
      const text = tail + buf.toString('latin1', 0, bytesRead);
      let match;
      regex.lastIndex = 0;
      while ((match = regex.exec(text)) !== null) found.add(match[0]);
      tail = text.slice(-64);
    }
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
  return found;
}

// ---- claude -----------------------------------------------------------------

const CLAUDE_FAMILY_LABEL = {
  opus: 'Opus',
  sonnet: 'Sonnet',
  haiku: 'Haiku',
  fable: 'Fable',
};
const CLAUDE_FAMILY_ORDER = ['opus', 'sonnet', 'haiku', 'fable'];
const CLAUDE_ID_RE = /claude-(?:opus|sonnet|haiku|fable)-\d+(?:-\d+)*/g;

// Collapse the many raw ids (dated snapshots, -v1, -fast, -0 aliases) into one
// canonical "family major[.minor]" entry each, e.g. claude-opus-4-1-20250805
// and claude-opus-4-1 both fold to claude-opus-4-1 / "Opus 4.1".
function parseClaudeModels(raw) {
  const byId = new Map();
  for (const token of raw) {
    const m = /^claude-(opus|sonnet|haiku|fable)-(\d+(?:-\d+)*)$/.exec(token);
    if (!m) continue;
    const family = m[1];
    const parts = m[2].split('-');
    const major = parts[0];
    let minor = parts[1];
    // A real minor is 1-2 digits; an 8-digit group is a date snapshot, and a
    // trailing 0 (4-0) is just the base version.
    if (minor === undefined || minor.length > 2 || minor === '0') minor = null;
    const id = minor
      ? `claude-${family}-${major}-${minor}`
      : `claude-${family}-${major}`;
    if (byId.has(id)) continue;
    byId.set(id, {
      id,
      label: `${CLAUDE_FAMILY_LABEL[family]} ${major}${minor ? `.${minor}` : ''}`,
      args: ['--model', id],
      _sort: [CLAUDE_FAMILY_ORDER.indexOf(family), Number(major), Number(minor || 0)],
    });
  }
  return sortByFamilyThenVersionDesc([...byId.values()]);
}

// ---- codex -------------------------------------------------------------------

// Codex's launcher is a thin JS shim; the model strings live in the vendored
// Rust binary. Match the dotted gpt-N.M family plus size variants; the
// specialized -codex* ids are skipped (unverified for non-interactive exec).
const CODEX_ID_RE = /gpt-\d+\.\d+(?:-(?:mini|nano|pro))?/g;
// Floor out older versions. A plain id like "gpt-5.3" is often just the prefix
// of a -codex-only release, so it isn't a real standalone exec model; the
// current exec line is gpt-5.4+. Future majors/minors pass automatically.
const CODEX_MIN_MAJOR = 5;
const CODEX_MIN_MINOR = 4;

function parseCodexModels(raw) {
  const byId = new Map();
  for (const token of raw) {
    const m = /^gpt-(\d+)\.(\d+)(?:-(mini|nano|pro))?$/.exec(token);
    if (!m) continue;
    const [, major, minor, suffix] = m;
    const maj = Number(major);
    const min = Number(minor);
    if (maj < CODEX_MIN_MAJOR || (maj === CODEX_MIN_MAJOR && min < CODEX_MIN_MINOR)) {
      continue;
    }
    if (byId.has(token)) continue;
    const suffixLabel = suffix
      ? ` ${suffix.charAt(0).toUpperCase()}${suffix.slice(1)}`
      : '';
    byId.set(token, {
      id: token,
      label: `GPT-${major}.${minor}${suffixLabel}`,
      args: ['-m', token],
      _sort: [0, Number(major), Number(minor)],
      _variant: suffix ? 1 : 0,
    });
  }
  // Plain (non-variant) ids rank above their -mini/-nano/-pro siblings of the
  // same version so the strongest model of the newest version is the default.
  const list = [...byId.values()];
  list.sort(
    (a, b) =>
      b._sort[1] - a._sort[1] ||
      b._sort[2] - a._sort[2] ||
      a._variant - b._variant,
  );
  return list.map(({ _sort, _variant, ...rest }) => rest);
}

// ---- agy ---------------------------------------------------------------------

// agy has no greppable slugs but ships an `agy models` command that prints
// human-readable names. We pass the printed name straight back as --model; the
// exact arg format is unverified, so this is a best-effort scaffold.
function discoverAgyModels() {
  const result = spawnSync('agy', ['models'], {
    encoding: 'utf8',
    timeout: 8000,
  });
  if (result.status !== 0) return null;
  const byId = new Map();
  for (const rawLine of String(result.stdout || '').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;
    // Drop any help/usage noise that isn't a model name.
    if (/^(usage|flags?|list available|-h\b|--help\b)/i.test(line)) continue;
    const id = line
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '');
    if (!id || byId.has(id)) continue;
    byId.set(id, { id, label: line, args: ['--model', line] });
  }
  return byId.size ? [...byId.values()] : null;
}

// ---- shared helpers ----------------------------------------------------------

function sortByFamilyThenVersionDesc(list) {
  list.sort(
    (a, b) =>
      a._sort[0] - b._sort[0] ||
      b._sort[1] - a._sort[1] ||
      b._sort[2] - a._sort[2],
  );
  return list.map(({ _sort, ...rest }) => rest);
}

// `codex` on PATH is a thin JS launcher; the real model strings live in a
// per-platform vendored Rust binary inside the package. Walk from the launcher
// to <pkg>/node_modules/@openai/codex-<platform>/vendor/<target>/bin/codex.
function locateCodexBinary() {
  const launcher = resolveBinary('codex');
  if (!launcher) return null;
  const pkgRoot = path.dirname(path.dirname(launcher));
  const vendorParent = path.join(pkgRoot, 'node_modules', '@openai');
  let scopes;
  try {
    scopes = fs.readdirSync(vendorParent);
  } catch (_err) {
    return launcher;
  }
  for (const name of scopes) {
    if (!name.startsWith('codex-')) continue;
    const vendorDir = path.join(vendorParent, name, 'vendor');
    let targets;
    try {
      targets = fs.readdirSync(vendorDir);
    } catch (_err) {
      continue;
    }
    for (const target of targets) {
      for (const exe of ['codex', 'codex.exe']) {
        const candidate = path.join(vendorDir, target, 'bin', exe);
        if (fs.existsSync(candidate)) return fs.realpathSync(candidate);
      }
    }
  }
  return launcher;
}

const STRATEGIES = {
  claude: {
    locate: () => resolveBinary('claude'),
    discover: (bin) => {
      const list = parseClaudeModels(scanFile(bin, CLAUDE_ID_RE));
      return list.length ? list : null;
    },
  },
  codex: {
    locate: () => locateCodexBinary(),
    discover: (bin) => {
      const list = parseCodexModels(scanFile(bin, CODEX_ID_RE));
      return list.length ? list : null;
    },
  },
  agy: {
    // Resolve the launcher only for cache-stamping; discovery shells out to
    // `agy models` rather than reading the (stripped) binary.
    locate: () => resolveBinary('agy'),
    discover: () => discoverAgyModels(),
  },
};

// Discovered model options for an agent, or null to fall back to the static
// catalog. Cached and keyed by the binary stamp so a CLI update refreshes it.
function discoverModels(agentKey) {
  if (DISABLED) return null;
  const strategy = STRATEGIES[agentKey];
  if (!strategy) return null;
  try {
    const bin = strategy.locate();
    if (!bin) return null;
    const stamp = fileStamp(bin);
    const cached = cache.get(agentKey);
    if (cached && cached.stamp === stamp) return cached.models;
    let models = null;
    try {
      models = strategy.discover(bin);
    } catch (_err) {
      models = null;
    }
    const normalized = Array.isArray(models) && models.length ? models : null;
    cache.set(agentKey, { stamp, models: normalized });
    return normalized;
  } catch (_err) {
    return null;
  }
}

module.exports = { discoverModels };
