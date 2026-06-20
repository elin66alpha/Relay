'use strict';

const { spawn } = require('child_process');
const { randomUUID } = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { commandExists } = require('./agents');

const SESSION_TTL_MS = 15 * 60 * 1000;
const SESSION_MAX_RUNNING_MS = 15 * 60 * 1000;
const URL_RE = /https?:\/\/[^\s"'<>]+/g;
const AGY_TOKEN_RELATIVE = [
  '.gemini',
  'antigravity-cli',
  'antigravity-oauth-token',
];

const LOGIN_COMMANDS = {
  claude: ['claude', 'auth', 'login', '--claudeai'],
  codex: ['codex', 'login', '--device-auth'],
  agy: ['agy'],
};

function agyTokenPath(homeDir) {
  return path.join(homeDir, ...AGY_TOKEN_RELATIVE);
}

function hasNonEmptyFile(fsModule, filePath) {
  try {
    return String(fsModule.readFileSync(filePath, 'utf8')).trim().length > 0;
  } catch (_err) {
    return false;
  }
}

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
  const fsModule = options.fs || fs;
  const homeDir = options.homeDir || os.homedir();
  const pollIntervalMs = options.pollIntervalMs || 1000;
  const sessionTtlMs = options.sessionTtlMs || SESSION_TTL_MS;
  const maxRunningMs = options.maxRunningMs || SESSION_MAX_RUNNING_MS;

  function sessionPayload(session) {
    return {
      sessionId: session.id,
      agent: session.agent,
      authMode: session.authMode,
      requiresCode: session.requiresCode,
    };
  }

  function emit(session, type, payload = {}) {
    const event = {
      type,
      data: {
        ...sessionPayload(session),
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
      data: sessionPayload(session),
    });
    if (session.url) {
      listener({
        type: 'login_url',
        data: { ...sessionPayload(session), url: session.url },
      });
    }
    if (session.status === 'done') {
      listener({
        type: 'login_done',
        data: sessionPayload(session),
      });
    } else if (session.status === 'error') {
      listener({
        type: 'login_error',
        data: {
          ...sessionPayload(session),
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
    if (session.pollTimer) {
      clearInterval(session.pollTimer);
      session.pollTimer = null;
    }
    session.status = status;
    session.error = error;
    session.finishedAt = nowFn();
    emit(session, status === 'done' ? 'login_done' : 'login_error', {
      ...(error ? { error } : {}),
    });
  }

  function killChild(session) {
    if (!session.child || typeof session.child.kill !== 'function') return;
    try {
      session.child.kill('SIGTERM');
    } catch (_err) {
      // The child may already have exited; finish() still records the terminal state.
    }
  }

  function abortSession(session, message) {
    if (session.status !== 'running') return;
    killChild(session);
    finish(session, 'error', message);
  }

  function cleanup() {
    const now = nowFn();
    for (const [id, session] of sessions.entries()) {
      if (
        session.status === 'running'
        && now - session.createdAt > maxRunningMs
      ) {
        abortSession(session, 'Login session timed out.');
      }
      if (
        session.status !== 'running'
        && now - (session.finishedAt || session.createdAt) > sessionTtlMs
      ) {
        sessions.delete(id);
      }
    }
  }

  function startAgyTokenPoll(session) {
    const tokenPath = agyTokenPath(homeDir);
    session.pollTimer = setInterval(() => {
      if (hasNonEmptyFile(fsModule, tokenPath)) {
        finish(session, 'done');
      }
    }, pollIntervalMs);
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
      authMode: agent === 'agy' ? 'browserOAuth' : 'deviceCode',
      requiresCode: agent !== 'agy',
      createdAt: nowFn(),
      finishedAt: null,
      listeners: new Set(),
      child: null,
      pollTimer: null,
    };
    sessions.set(id, session);

    if (agent === 'agy' && hasNonEmptyFile(fsModule, agyTokenPath(homeDir))) {
      finish(session, 'done');
      return session;
    }

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
      if (session.agent === 'agy') {
        if (hasNonEmptyFile(fsModule, agyTokenPath(homeDir))) {
          finish(session, 'done');
        } else {
          finish(
            session,
            'error',
            signal
              ? `Agy login process ended with signal ${signal}.`
              : `Agy login process exited before the OAuth token appeared (code ${code}).`,
          );
        }
        return;
      }
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
    if (agent === 'agy') startAgyTokenPoll(session);
    emit(session, 'login_started');
    return session;
  }

  function subscribe(sessionId, listener) {
    cleanup();
    const session = sessions.get(sessionId);
    if (!session) return () => {};
    session.listeners.add(listener);
    replay(session, listener);
    return () => {
      if (!session.listeners.has(listener)) return;
      session.listeners.delete(listener);
      if (session.status === 'running' && session.listeners.size === 0) {
        abortSession(session, 'Login client disconnected.');
      }
    };
  }

  function submitCode(sessionId, code) {
    const session = sessions.get(sessionId);
    if (!session) {
      const err = new Error('Login session not found.');
      err.code = 'LOGIN_SESSION_NOT_FOUND';
      throw err;
    }
    if (!session.requiresCode) {
      const err = new Error('Login session does not accept an authorization code.');
      err.code = 'LOGIN_CODE_NOT_REQUIRED';
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
    cleanup();
    const session = sessions.get(sessionId);
    if (!session) return null;
    return {
      sessionId: session.id,
      agent: session.agent,
      status: session.status,
      url: session.url,
      error: session.error,
      authMode: session.authMode,
      requiresCode: session.requiresCode,
    };
  }

  return { start, subscribe, submitCode, status, cleanup };
}

module.exports = {
  LOGIN_COMMANDS,
  agyTokenPath,
  createAgentLoginManager,
  scriptCommand,
};
