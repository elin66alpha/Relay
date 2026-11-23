'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { test } = require('node:test');

test('a CLI missing from PATH is found in ~/.local/bin', { skip: process.platform === 'win32' }, () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-cli-paths-'));
  const bin = path.join(home, '.local', 'bin');
  fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(path.join(bin, 'claude'), '#!/bin/sh\n', { mode: 0o755 });
  const saved = { HOME: process.env.HOME, PATH: process.env.PATH };
  process.env.HOME = home;
  process.env.PATH = '';
  try {
    const { commandExists, locateBin } = require('../lib/cli-paths');
    assert.equal(locateBin('claude'), path.join(bin, 'claude'));
    assert.equal(commandExists('codex'), false);
  } finally {
    Object.assign(process.env, saved);
    fs.rmSync(home, { recursive: true, force: true });
  }
});

// npm's Windows launcher for a Node CLI (as installed for codex) and for a
// native binary. Node cannot spawn either .cmd without a shell.
const NODE_SHIM = [
  '@ECHO off',
  'SETLOCAL',
  'IF EXIST "%dp0%\\node.exe" (',
  '  SET "_prog=%dp0%\\node.exe"',
  ') ELSE (',
  '  SET "_prog=node"',
  ')',
  'endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\node_modules\\tool\\bin\\tool.js" %*',
  '',
].join('\r\n');
const EXE_SHIM = '@ECHO off\r\n"%~dp0\\node_modules\\tool\\bin\\tool.exe"   %*\r\n';

function withShim(name, shim, target, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-cli-shim-'));
  fs.writeFileSync(path.join(dir, `${name}.cmd`), shim);
  fs.mkdirSync(path.dirname(path.join(dir, target)), { recursive: true });
  fs.writeFileSync(path.join(dir, target), '');
  const saved = { PATH: process.env.PATH, PATHEXT: process.env.PATHEXT };
  process.env.PATH = dir;
  process.env.PATHEXT = '.EXE;.CMD';
  try {
    fn(dir);
  } finally {
    Object.assign(process.env, saved);
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('an npm .cmd launcher for a Node CLI runs its script with Node', { skip: process.platform !== 'win32' }, () => {
  const { cliCommand } = require('../lib/cli-paths');
  withShim('relaytestnode', NODE_SHIM, 'node_modules/tool/bin/tool.js', (dir) => {
    assert.deepEqual(cliCommand('relaytestnode', ['--version']), {
      cmd: process.execPath,
      args: [path.join(dir, 'node_modules', 'tool', 'bin', 'tool.js'), '--version'],
    });
  });
});

test('an npm .cmd launcher for a native binary runs the binary', { skip: process.platform !== 'win32' }, () => {
  const { cliCommand } = require('../lib/cli-paths');
  withShim('relaytestexe', EXE_SHIM, 'node_modules/tool/bin/tool.exe', (dir) => {
    assert.deepEqual(cliCommand('relaytestexe', ['acp']), {
      cmd: path.join(dir, 'node_modules', 'tool', 'bin', 'tool.exe'),
      args: ['acp'],
    });
  });
});

test('cliCommand is null for a CLI that is not installed', () => {
  const { cliCommand } = require('../lib/cli-paths');
  assert.equal(cliCommand('relay-no-such-cli-xyz'), null);
});

test('a login shell session left in the backend env does not reach agents', () => {
  const { dropLoginSessionEnv } = require('../lib/cli-paths');
  const env = {
    PATH: '/usr/bin',
    SSH_CONNECTION: '1 2 3 4',
    SSH_CLIENT: '1 2 3',
    SSH_TTY: '/dev/pts/0',
    SSH_AUTH_SOCK: '/tmp/agent.sock',
    ANTIGRAVITY_AGENT: '1',
    ANTIGRAVITY_LS_ADDRESS: 'localhost:1',
  };
  assert.deepEqual(dropLoginSessionEnv(env), { PATH: '/usr/bin', SSH_AUTH_SOCK: '/tmp/agent.sock' });
});
