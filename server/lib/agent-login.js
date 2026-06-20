'use strict';

const { spawn } = require('child_process');
const { randomUUID } = require('crypto');

const { commandExists } = require('./agents');

const SESSION_TTL_MS = 15 * 60 * 1000;
const URL_RE = /https?:\/\/[^\s"'<>]+/g;

const LOGIN_COMMANDS = {
  claude: ['claude', 'auth', 'login', '--claudeai'],
  codex: ['codex', 'login', '--device-auth'],
  agy: ['agy'],
};

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function scriptCommand(args) {
  return args.map(shellQuote).join(' ');
}

function redactLoginText(text) {
  return String(text || '').replace(URL_RE, '[login URL]');
}

function createAgentLoginManager(options = {}) {
  const sessions = new Map();
  const spawnFn = options.spawn || spawn;
  const nowFn = options.now || (() => Date.now());
  const idFn = options.randomUUID || randomUUID;
  const commandExistsFn = options.commandExists || commandExists;

  function emit(session, type, payload = {}) {
    const event = {
      type,
      data: {
        sessionId: session.id,
        agent: session.agent,
        ...payload,
      },
    };
    for (const listener of session.listeners) {
      try {
        listener(event);
      } catch (_err) {
        // A dropped SSE client should not affect the login process.
      }
    }
  }

  function replay(session, listener) {
    listener({
      type: 'login_started',
      data: { sessionId: session.id, agent: session.agent },
    });
    if (session.url) {
      listener({
        type: 'login_url',
        data: { sessionId: session.id, agent: session.agent, url: session.url },
      });
    }
    if (session.status === 'done') {
      listener({
        type: 'login_done',
        data: { sessionId: session.id, agent: session.agent },
      });
    } else if (session.status === 'error') {
      listener({
        type: 'login_error',
        data: {
          sessionId: session.id,
          agent: session.agent,
          error: session.error || 'Login failed.',
        },
      });
    }
  }

  function handleOutput(session, chunk) {
    const text = String(chunk || '');
    session.output += text;
    const urls = text.match(URL_RE) || [];
    if (urls.length > 0 && session.url !== urls[0]) {
      session.url = urls[0];
      emit(session, 'login_url', { url: session.url });
    }
    if (!session.codeSubmitted && text.trim()) {
      emit(session, 'login_output', { text: redactLoginText(text).slice(-2000) });
    }
  }

  function finish(session, status, error = '') {
    if (session.status !== 'running') return;
    session.status = status;
    session.error = error;
    session.finishedAt = nowFn();
    emit(session, status === 'done' ? 'login_done' : 'login_error', {
      ...(error ? { error } : {}),
    });
  }

  function cleanup() {
    const now = nowFn();
    for (const [id, session] of sessions.entries()) {
      if (session.status === 'running') continue;
      if (now - (session.finishedAt || session.createdAt) > SESSION_TTL_MS) {
        sessions.delete(id);
      }
    }
  }

  function start(agent) {
    cleanup();
    const args = LOGIN_COMMANDS[agent];
    if (!args) {
      const err = new Error(`Login is not supported for ${agent}`);
      err.code = 'LOGIN_UNSUPPORTED';
      throw err;
    }
    if (!commandExistsFn(args[0])) {
      const err = new Error(`${agent} CLI is not installed`);
      err.code = 'CLI_NOT_INSTALLED';
      throw err;
    }
    const id = idFn();
    const session = {
      id,
      agent,
      status: 'running',
      url: '',
      output: '',
      error: '',
      codeSubmitted: false,
      createdAt: nowFn(),
      finishedAt: null,
      listeners: new Set(),
      child: null,
    };
    sessions.set(id, session);

    const child = spawnFn(
      'script',
      ['-qfec', scriptCommand(args), '/dev/null'],
      { stdio: ['pipe', 'pipe', 'pipe'] },
    );
    session.child = child;
    child.stdout?.on('data', (chunk) => handleOutput(session, chunk));
    child.stderr?.on('data', (chunk) => handleOutput(session, chunk));
    child.on('error', (err) => {
      finish(session, 'error', err.message || 'Failed to start login.');
    });
    child.on('exit', (code, signal) => {
      if (code === 0) {
        finish(session, 'done');
      } else {
        finish(
          session,
          'error',
          signal
            ? `Login process ended with signal ${signal}.`
            : `Login process exited with code ${code}.`,
        );
      }
    });
    emit(session, 'login_started');
    return session;
  }

  function subscribe(sessionId, listener) {
    const session = sessions.get(sessionId);
    if (!session) return () => {};
    session.listeners.add(listener);
    replay(session, listener);
    return () => session.listeners.delete(listener);
  }

  function submitCode(sessionId, code) {
    const session = sessions.get(sessionId);
    if (!session) {
      const err = new Error('Login session not found.');
      err.code = 'LOGIN_SESSION_NOT_FOUND';
      throw err;
    }
    if (session.status !== 'running' || !session.child?.stdin?.writable) {
      const err = new Error('Login session is not accepting input.');
      err.code = 'LOGIN_SESSION_CLOSED';
      throw err;
    }
    session.codeSubmitted = true;
    session.child.stdin.write(`${String(code || '').trim()}\n`);
  }

  function status(sessionId) {
    const session = sessions.get(sessionId);
    if (!session) return null;
    return {
      sessionId: session.id,
      agent: session.agent,
      status: session.status,
      url: session.url,
      error: session.error,
    };
  }

  return { start, subscribe, submitCode, status, cleanup };
}

module.exports = {
  LOGIN_COMMANDS,
  createAgentLoginManager,
  scriptCommand,
};
