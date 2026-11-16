'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  WorkdirError,
  resolveWorkdir,
  getDefaultWorkdir,
  resolveRequestWorkdir,
  inspectWorkdir,
  validateWorkdir,
  getWorkspaceRoot,
  assertInsideWorkspace,
} = require('../lib/workdir');

function scratchDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'relay-workdir-'));
}

// Run fn, asserting it throws, and return the thrown error (assert.throws itself
// returns undefined, so it can't be used to inspect the error).
function caught(fn) {
  try {
    fn();
  } catch (err) {
    return err;
  }
  throw new assert.AssertionError({ message: 'expected the call to throw' });
}

// --- resolveWorkdir: the sandbox boundary -----------------------------------

test('resolveWorkdir rejects an empty path', () => {
  const err = caught(() => resolveWorkdir(''));
  assert.ok(err instanceof WorkdirError);
  assert.equal(err.code, 'WORKDIR_PATH_REQUIRED');
});

test('resolveWorkdir rejects a relative path', () => {
  for (const value of ['relative/dir', 'dir', './x', '../escape']) {
    const err = caught(() => resolveWorkdir(value));
    assert.ok(err instanceof WorkdirError);
    assert.equal(err.code, 'WORKDIR_NOT_ABSOLUTE', `for ${value}`);
  }
});

test('resolveWorkdir refuses the filesystem root', () => {
  const err = caught(() => resolveWorkdir('/'));
  assert.ok(err instanceof WorkdirError);
  assert.equal(err.code, 'WORKDIR_ROOT_NOT_ALLOWED');
});

test('resolveWorkdir returns the canonical absolute path', () => {
  assert.equal(resolveWorkdir('/foo/bar'), path.resolve('/foo/bar'));
  // Surrounding whitespace is trimmed.
  assert.equal(resolveWorkdir('  /foo/bar  '), path.resolve('/foo/bar'));
});

test('resolveWorkdir normalizes .. segments so the result cannot dangle outside itself', () => {
  // path.resolve collapses traversal: the returned path is always canonical.
  assert.equal(resolveWorkdir('/foo/bar/../baz'), path.resolve('/foo/baz'));
  assert.equal(resolveWorkdir('/foo/./bar'), path.resolve('/foo/bar'));
});

test('resolveWorkdir expands ~ to the home directory', () => {
  assert.equal(resolveWorkdir('~'), path.resolve(os.homedir()));
  assert.equal(resolveWorkdir('~/projects'), path.join(os.homedir(), 'projects'));
});

// --- getDefaultWorkdir / resolveRequestWorkdir ------------------------------

test('getDefaultWorkdir honors RELAY_DEFAULT_DIR', () => {
  const prev = process.env.RELAY_DEFAULT_DIR;
  const dir = scratchDir();
  try {
    process.env.RELAY_DEFAULT_DIR = path.join(dir, 'custom-default');
    assert.equal(getDefaultWorkdir(), path.join(dir, 'custom-default'));
  } finally {
    if (prev === undefined) delete process.env.RELAY_DEFAULT_DIR;
    else process.env.RELAY_DEFAULT_DIR = prev;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('getDefaultWorkdir uses a Relay folder in the home directory by default', () => {
  const prev = process.env.RELAY_DEFAULT_DIR;
  try {
    delete process.env.RELAY_DEFAULT_DIR;
    assert.equal(getDefaultWorkdir(), path.join(os.homedir(), 'Relay'));
  } finally {
    if (prev === undefined) delete process.env.RELAY_DEFAULT_DIR;
    else process.env.RELAY_DEFAULT_DIR = prev;
  }
});

test('resolveRequestWorkdir creates a missing default dir and returns it', () => {
  const prev = process.env.RELAY_DEFAULT_DIR;
  const dir = scratchDir();
  const target = path.join(dir, 'made-on-demand');
  try {
    process.env.RELAY_DEFAULT_DIR = target;
    assert.equal(fs.existsSync(target), false);
    const resolved = resolveRequestWorkdir('');
    assert.equal(resolved, target);
    assert.equal(fs.existsSync(target), true);
  } finally {
    if (prev === undefined) delete process.env.RELAY_DEFAULT_DIR;
    else process.env.RELAY_DEFAULT_DIR = prev;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('resolveRequestWorkdir uses the header path when present', () => {
  const dir = scratchDir();
  try {
    const resolved = resolveRequestWorkdir(dir);
    // resolveWorkdir uses path.resolve (lexical), not realpath, so it returns
    // the canonical form of the given absolute path unchanged.
    assert.equal(resolved, path.resolve(dir));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- inspectWorkdir / validateWorkdir ---------------------------------------

test('inspectWorkdir reports existence and directory-ness', () => {
  const dir = scratchDir();
  try {
    const info = inspectWorkdir(dir);
    assert.equal(info.dir, dir);
    assert.equal(info.exists, true);
    assert.equal(info.isDirectory, true);

    const missing = inspectWorkdir(path.join(dir, 'nope'));
    assert.equal(missing.exists, false);
    assert.equal(missing.isDirectory, false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('validateWorkdir 404s on a missing dir unless create is set', () => {
  const dir = scratchDir();
  const target = path.join(dir, 'child');
  try {
    const err = caught(() => validateWorkdir(target));
    assert.ok(err instanceof WorkdirError);
    assert.equal(err.code, 'WORKDIR_NOT_FOUND');
    assert.equal(err.status, 404);

    const result = validateWorkdir(target, { create: true });
    assert.equal(result.dir, target);
    assert.equal(result.created, true);
    assert.equal(fs.existsSync(target), true);

    // Already exists now: no longer reports created.
    assert.deepEqual(validateWorkdir(target), { dir: target, created: false });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('validateWorkdir rejects a path that points at a file', () => {
  const dir = scratchDir();
  const file = path.join(dir, 'a-file');
  try {
    fs.writeFileSync(file, 'x');
    const err = caught(() => validateWorkdir(file));
    assert.ok(err instanceof WorkdirError);
    assert.equal(err.code, 'WORKDIR_NOT_DIRECTORY');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- RELAY_WORKSPACE_ROOT: an isolated install -------------------------------

function withWorkspaceRoot(root, fn) {
  const prev = {
    root: process.env.RELAY_WORKSPACE_ROOT,
    dir: process.env.RELAY_DEFAULT_DIR,
  };
  process.env.RELAY_WORKSPACE_ROOT = root;
  delete process.env.RELAY_DEFAULT_DIR;
  try {
    return fn();
  } finally {
    for (const [key, value] of [
      ['RELAY_WORKSPACE_ROOT', prev.root],
      ['RELAY_DEFAULT_DIR', prev.dir],
    ]) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

test('an isolated install accepts the workspace root and paths inside it', () => {
  const root = fs.realpathSync(scratchDir());
  withWorkspaceRoot(root, () => {
    assert.equal(resolveWorkdir(root), root);
    assert.equal(resolveWorkdir(path.join(root, 'project')), path.join(root, 'project'));
    assert.equal(getDefaultWorkdir(), root);
    assert.equal(validateWorkdir(path.join(root, 'new'), { create: true }).created, true);
  });
});

test('an isolated install refuses workdirs outside the workspace', () => {
  const root = fs.realpathSync(scratchDir());
  const outside = fs.realpathSync(scratchDir());
  withWorkspaceRoot(root, () => {
    for (const dir of [outside, path.dirname(root), `${root}-sibling`, path.join(root, '..', 'x')]) {
      const err = caught(() => resolveWorkdir(dir));
      assert.equal(err.code, 'WORKDIR_OUTSIDE_WORKSPACE', dir);
      assert.equal(err.status, 403);
    }
    assert.equal(caught(() => resolveRequestWorkdir(outside)).code, 'WORKDIR_OUTSIDE_WORKSPACE');
    assert.equal(
      caught(() => validateWorkdir(path.join(outside, 'new'), { create: true })).code,
      'WORKDIR_OUTSIDE_WORKSPACE',
    );
    assert.equal(fs.existsSync(path.join(outside, 'new')), false);
  });
});

test('an isolated install refuses a link that leads out of the workspace', (t) => {
  const root = fs.realpathSync(scratchDir());
  const outside = fs.realpathSync(scratchDir());
  const link = path.join(root, 'link');
  try {
    fs.symlinkSync(outside, link, 'junction');
  } catch (_err) {
    t.skip('links are not available on this host');
    return;
  }
  withWorkspaceRoot(root, () => {
    assert.equal(caught(() => resolveWorkdir(link)).code, 'WORKDIR_OUTSIDE_WORKSPACE');
    assert.equal(
      caught(() => resolveWorkdir(path.join(link, 'deeper', 'new'))).code,
      'WORKDIR_OUTSIDE_WORKSPACE',
    );
  });
});

test('an isolated install keeps RELAY_DEFAULT_DIR only inside the workspace', () => {
  const root = fs.realpathSync(scratchDir());
  withWorkspaceRoot(root, () => {
    process.env.RELAY_DEFAULT_DIR = path.join(root, 'start');
    assert.equal(getDefaultWorkdir(), path.join(root, 'start'));
    process.env.RELAY_DEFAULT_DIR = os.tmpdir();
    assert.equal(getDefaultWorkdir(), root);
  });
});

test('a workspace root that is not absolute is an error, not open mode', () => {
  withWorkspaceRoot('workspace', () => {
    assert.equal(caught(() => getWorkspaceRoot()).code, 'WORKSPACE_ROOT_INVALID');
    assert.equal(caught(() => resolveWorkdir(os.tmpdir())).code, 'WORKSPACE_ROOT_INVALID');
  });
});

test('open mode leaves workdirs unrestricted', () => {
  assert.equal(getWorkspaceRoot(), null);
  assert.equal(assertInsideWorkspace(os.tmpdir()), os.tmpdir());
});
