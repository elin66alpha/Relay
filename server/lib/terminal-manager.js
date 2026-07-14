'use strict';

const crypto = require('crypto');
const os = require('os');

const DEFAULT_IDLE_TIMEOUT_MS = 12 * 60 * 60 * 1000;
const DEFAULT_BUFFER_MAX_BYTES = 2 * 1024 * 1024;
const TICKET_TTL_MS = 30 * 1000;
const MAX_INPUT_BYTES = 64 * 1024;

function boundedInteger(value, fallback, min, max) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= min && parsed <= max
    ? parsed
    : fallback;
}

function terminalError(message, code) {
  const err = new Error(message);
  err.code = code;
  return err;
}

function loadPty() {
  try {
    return require('node-pty');
  } catch (err) {
    console.error(`SSH terminal is unavailable: ${err.message}`);
    return null;
  }
}

function shellCommand(platform = process.platform, env = process.env) {
  if (platform === 'win32') {
    return {
      file: env.COMSPEC || 'powershell.exe',
      args: [],
    };
  }
  return {
    file: env.RELAY_TERMINAL_SHELL || env.SHELL || '/bin/sh',
    args: ['-l'],
  };
}

function createTerminalManager(options = {}) {
  const pty = options.pty === undefined ? loadPty() : options.pty;
  const now = options.now || (() => Date.now());
  const randomTicket =
    options.randomTicket || (() => crypto.randomBytes(32).toString('base64url'));
  const isTokenActive = options.isTokenActive || (() => true);
  const idleTimeoutMs = boundedInteger(
    options.idleTimeoutMs ?? process.env.TERMINAL_IDLE_TIMEOUT_MS,
    DEFAULT_IDLE_TIMEOUT_MS,
    60 * 1000,
    7 * 24 * 60 * 60 * 1000,
  );
  const bufferMaxBytes = boundedInteger(
    options.bufferMaxBytes ?? process.env.TERMINAL_BUFFER_MAX_BYTES,
    DEFAULT_BUFFER_MAX_BYTES,
    64 * 1024,
    16 * 1024 * 1024,
  );
  const tickets = new Map();
  const sessions = new Map();
  let webSocketServer = null;
  const heartbeatTimer = setInterval(() => {
    for (const session of sessions.values()) {
      if (!isTokenActive(session.tokenId)) {
        closeSession(session.tokenId);
        continue;
      }
      send(session.client, { type: 'ping' });
    }
  }, 25 * 1000);
  if (typeof heartbeatTimer.unref === 'function') heartbeatTimer.unref();

  function pruneTickets() {
    const timestamp = now();
    for (const [ticket, record] of tickets) {
      if (record.expiresAt <= timestamp) tickets.delete(ticket);
    }
  }

  function createTicket({ tokenId, cols, rows }) {
    if (!pty) {
      throw terminalError(
        'SSH terminal support is unavailable on this backend.',
        'TERMINAL_UNAVAILABLE',
      );
    }
    const cleanTokenId = String(tokenId || '').trim();
    if (!cleanTokenId) {
      throw terminalError('terminal token is required', 'TERMINAL_UNAUTHORIZED');
    }
    pruneTickets();
    const ticket = randomTicket();
    tickets.set(ticket, {
      tokenId: cleanTokenId,
      cols: boundedInteger(cols, 80, 2, 500),
      rows: boundedInteger(rows, 24, 2, 200),
      expiresAt: now() + TICKET_TTL_MS,
    });
    return { ticket, expiresInMs: TICKET_TTL_MS };
  }

  function consumeTicket(ticket) {
    const clean = String(ticket || '').trim();
    if (!clean) return null;
    const record = tickets.get(clean);
    tickets.delete(clean);
    if (
      !record ||
      record.expiresAt <= now() ||
      !isTokenActive(record.tokenId)
    ) {
      return null;
    }
    return record;
  }

  function send(client, payload) {
    if (!client || client.readyState !== 1) return;
    try {
      client.send(JSON.stringify(payload));
    } catch (_err) {
      // The socket close/error handler owns cleanup.
    }
  }

  function appendOutput(session, data) {
    const text = String(data || '');
    if (!text) return;
    const bytes = Buffer.byteLength(text);
    session.output.push({ text, bytes });
    session.outputBytes += bytes;
    while (
      session.outputBytes > bufferMaxBytes &&
      session.output.length > 1
    ) {
      session.outputBytes -= session.output.shift().bytes;
    }
    send(session.client, { type: 'output', data: text });
  }

  function removeSession(session) {
    if (sessions.get(session.tokenId) === session) {
      sessions.delete(session.tokenId);
    }
    if (session.idleTimer) clearTimeout(session.idleTimer);
    session.idleTimer = null;
  }

  function spawnSession(ticket) {
    const env = options.env || process.env;
    const command = shellCommand(options.platform, env);
    let processHandle;
    try {
      processHandle = pty.spawn(command.file, command.args, {
        name: 'xterm-256color',
        cols: ticket.cols,
        rows: ticket.rows,
        cwd: env.HOME || os.homedir(),
        env: {
          ...env,
          TERM: 'xterm-256color',
          COLORTERM: 'truecolor',
        },
      });
    } catch (err) {
      throw terminalError(
        `Could not start the SSH terminal: ${err.message}`,
        'TERMINAL_START_FAILED',
      );
    }

    const session = {
      tokenId: ticket.tokenId,
      pty: processHandle,
      client: null,
      output: [],
      outputBytes: 0,
      idleTimer: null,
    };
    sessions.set(ticket.tokenId, session);
    processHandle.onData((data) => appendOutput(session, data));
    processHandle.onExit(({ exitCode, signal }) => {
      send(session.client, { type: 'exit', exitCode, signal });
      if (session.client && session.client.readyState === 1) {
        session.client.close(1000, 'shell exited');
      }
      removeSession(session);
    });
    return session;
  }

  function scheduleIdleCleanup(session) {
    if (session.idleTimer) clearTimeout(session.idleTimer);
    session.idleTimer = setTimeout(() => {
      if (session.client) return;
      removeSession(session);
      try {
        session.pty.kill();
      } catch (_err) {
        // The shell may already have exited.
      }
    }, idleTimeoutMs);
    if (typeof session.idleTimer.unref === 'function') session.idleTimer.unref();
  }

  function closeSession(
    tokenId,
    code = 4003,
    reason = 'credential revoked',
  ) {
    const session = sessions.get(String(tokenId || '').trim());
    if (!session) return false;
    removeSession(session);
    const client = session.client;
    session.client = null;
    send(client, {
      type: 'error',
      code: 'TERMINAL_CREDENTIAL_REVOKED',
      message: 'This device credential was revoked.',
    });
    if (client && client.readyState === 1) client.close(code, reason);
    try {
      session.pty.kill();
    } catch (_err) {
      // The shell may already have exited.
    }
    return true;
  }

  function attachClient(ticket, client) {
    let session = sessions.get(ticket.tokenId);
    const resumed = !!session;
    if (!session) session = spawnSession(ticket);
    if (session.idleTimer) clearTimeout(session.idleTimer);
    session.idleTimer = null;

    const previousClient = session.client;
    session.client = client;
    if (previousClient && previousClient !== client) {
      send(previousClient, { type: 'replaced' });
      previousClient.close(4001, 'terminal opened elsewhere');
    }
    try {
      session.pty.resize(ticket.cols, ticket.rows);
    } catch (_err) {
      // A shell can exit between ticket redemption and attachment.
    }

    const replay = session.output.map((chunk) => chunk.text).join('');
    if (replay) send(client, { type: 'output', data: replay, replay: true });
    send(client, { type: 'ready', resumed });

    client.on('message', (raw, isBinary) => {
      if (isBinary) return;
      let message;
      try {
        message = JSON.parse(String(raw));
      } catch (_err) {
        return;
      }
      if (message.type === 'input') {
        const data = String(message.data || '');
        if (!data || Buffer.byteLength(data) > MAX_INPUT_BYTES) return;
        try {
          session.pty.write(data);
        } catch (_err) {
          // The exit event will close the socket.
        }
        return;
      }
      if (message.type === 'resize') {
        const cols = boundedInteger(message.cols, 0, 2, 500);
        const rows = boundedInteger(message.rows, 0, 2, 200);
        if (!cols || !rows) return;
        try {
          session.pty.resize(cols, rows);
        } catch (_err) {
          // The exit event will close the socket.
        }
      }
    });
    client.on('close', () => {
      if (session.client !== client) return;
      session.client = null;
      scheduleIdleCleanup(session);
    });
    client.on('error', () => {
      // ws emits close after error; cleanup happens there.
    });
    return { resumed };
  }

  function rejectUpgrade(socket, status = '401 Unauthorized') {
    try {
      socket.write(
        `HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`,
      );
    } finally {
      socket.destroy();
    }
  }

  function attachServer(server) {
    const { WebSocketServer } = require('ws');
    webSocketServer = new WebSocketServer({
      noServer: true,
      perMessageDeflate: false,
      maxPayload: MAX_INPUT_BYTES * 2,
    });
    server.on('upgrade', (req, socket, head) => {
      let url;
      try {
        url = new URL(req.url, 'http://relay.local');
      } catch (_err) {
        rejectUpgrade(socket, '400 Bad Request');
        return;
      }
      if (url.pathname !== '/api/terminal/connect') {
        rejectUpgrade(socket, '404 Not Found');
        return;
      }
      const ticket = consumeTicket(url.searchParams.get('ticket'));
      if (!ticket) {
        rejectUpgrade(socket);
        return;
      }
      webSocketServer.handleUpgrade(req, socket, head, (client) => {
        try {
          attachClient(ticket, client);
        } catch (err) {
          send(client, {
            type: 'error',
            code: err.code || 'TERMINAL_START_FAILED',
            message: err.message,
          });
          client.close(1011, 'terminal unavailable');
        }
      });
    });
  }

  function closeAll() {
    clearInterval(heartbeatTimer);
    for (const session of sessions.values()) {
      if (session.client && session.client.readyState === 1) {
        session.client.close(1001, 'server stopping');
      }
      try {
        session.pty.kill();
      } catch (_err) {
        // Best-effort shutdown.
      }
      if (session.idleTimer) clearTimeout(session.idleTimer);
    }
    sessions.clear();
    tickets.clear();
    if (webSocketServer) webSocketServer.close();
  }

  return {
    get available() {
      return !!pty;
    },
    attachClient,
    attachServer,
    closeAll,
    closeSession,
    consumeTicket,
    createTicket,
  };
}

module.exports = {
  createTerminalManager,
  shellCommand,
};
