'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { test } = require('node:test');

const {
  createTerminalManager,
  shellCommand,
} = require('../lib/terminal-manager');

class FakePtyProcess {
  constructor() {
    this.writes = [];
    this.resizes = [];
    this.killed = false;
  }

  onData(callback) {
    this.onDataCallback = callback;
  }

  onExit(callback) {
    this.onExitCallback = callback;
  }

  write(data) {
    this.writes.push(data);
  }

  resize(cols, rows) {
    this.resizes.push([cols, rows]);
  }

  kill() {
    this.killed = true;
  }
}

class FakeClient extends EventEmitter {
  constructor() {
    super();
    this.readyState = 1;
    this.sent = [];
  }

  send(data) {
    this.sent.push(JSON.parse(data));
  }

  close(code, reason) {
    this.closeCode = code;
    this.closeReason = reason;
    this.readyState = 3;
    this.emit('close');
  }
}

function fakePtyModule() {
  const processes = [];
  return {
    processes,
    spawn(file, args, options) {
      const process = new FakePtyProcess();
      process.spawn = { file, args, options };
      processes.push(process);
      return process;
    },
  };
}

test('terminal tickets are short-lived and single use', () => {
  let timestamp = 1000;
  const manager = createTerminalManager({
    pty: fakePtyModule(),
    now: () => timestamp,
    randomTicket: () => 'one-time-ticket',
  });

  const result = manager.createTicket({ tokenId: 'token-1', cols: 120, rows: 40 });
  assert.equal(result.ticket, 'one-time-ticket');
  assert.deepEqual(manager.consumeTicket(result.ticket), {
    tokenId: 'token-1',
    cols: 120,
    rows: 40,
    expiresAt: 31000,
  });
  assert.equal(manager.consumeTicket(result.ticket), null);

  manager.createTicket({ tokenId: 'token-1' });
  timestamp = 31000;
  assert.equal(manager.consumeTicket('one-time-ticket'), null);
  manager.closeAll();
});

test('a revoked token cannot redeem an already issued ticket', () => {
  let active = true;
  const manager = createTerminalManager({
    pty: fakePtyModule(),
    isTokenActive: () => active,
    randomTicket: () => 'revoked-ticket',
  });
  manager.createTicket({ tokenId: 'token-1' });
  active = false;
  assert.equal(manager.consumeTicket('revoked-ticket'), null);
  manager.closeAll();
});

test('one token resumes one PTY and replaces an older terminal window', () => {
  const pty = fakePtyModule();
  let ticketNumber = 0;
  const manager = createTerminalManager({
    pty,
    randomTicket: () => `ticket-${++ticketNumber}`,
    env: { HOME: '/home/relay', SHELL: '/bin/bash', PATH: '/usr/bin' },
    platform: 'linux',
  });

  const firstTicket = manager.consumeTicket(
    manager.createTicket({ tokenId: 'token-1', cols: 90, rows: 30 }).ticket,
  );
  const firstClient = new FakeClient();
  assert.deepEqual(manager.attachClient(firstTicket, firstClient), {
    resumed: false,
  });
  assert.equal(pty.processes.length, 1);
  assert.equal(pty.processes[0].spawn.file, '/bin/bash');
  assert.deepEqual(pty.processes[0].spawn.args, ['-l']);
  assert.equal(pty.processes[0].spawn.options.cwd, '/home/relay');

  firstClient.emit(
    'message',
    JSON.stringify({ type: 'input', data: 'pwd\r' }),
    false,
  );
  assert.deepEqual(pty.processes[0].writes, ['pwd\r']);
  pty.processes[0].onDataCallback('/home/relay\r\n');

  const secondTicket = manager.consumeTicket(
    manager.createTicket({ tokenId: 'token-1', cols: 100, rows: 35 }).ticket,
  );
  const secondClient = new FakeClient();
  assert.deepEqual(manager.attachClient(secondTicket, secondClient), {
    resumed: true,
  });
  assert.equal(pty.processes.length, 1);
  assert.equal(firstClient.closeCode, 4001);
  assert.deepEqual(secondClient.sent[0], {
    type: 'output',
    data: '/home/relay\r\n',
    replay: true,
  });
  assert.deepEqual(secondClient.sent[1], { type: 'ready', resumed: true });
  assert.deepEqual(pty.processes[0].resizes.at(-1), [100, 35]);
  assert.equal(manager.closeSession('token-1'), true);
  assert.equal(secondClient.closeCode, 4003);
  assert.equal(pty.processes[0].killed, true);
  assert.equal(manager.closeSession('token-1'), false);
  manager.closeAll();
});

test('shell command uses a login shell and supports Windows', () => {
  assert.deepEqual(shellCommand('linux', { SHELL: '/bin/zsh' }), {
    file: '/bin/zsh',
    args: ['-l'],
  });
  assert.deepEqual(shellCommand('win32', { COMSPEC: 'cmd.exe' }), {
    file: 'cmd.exe',
    args: [],
  });
});
