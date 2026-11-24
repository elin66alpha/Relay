'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const { boundedInteger } = require('./bounded-integer');
const { createSessionSlots } = require('./session-slots');

// Persistent agent sessions over a line-delimited JSON-RPC process.
//
// Relay used to run one CLI process per turn: the process died the moment the
// turn ended, so anything it started in the background died with it, and every
// turn paid the cold-start cost of booting the CLI again.
//
// opencode, hermes, agy, and cursor speak ACP (`<agent> acp`); codex speaks its own app-server
// protocol (`codex app-server`). Both are JSON-RPC 2.0 on stdio, and in both one
// process hosts *many* sessions (the working directory is chosen per session),
// so a pool keeps a single process per agent and multiplexes every chat through
// it. This pays each CLI's substantial startup cost once instead of once per
// chat.
//
// This module owns everything the two protocols share — the process, the wire,
// the session cap, idle eviction and cancellation — and takes a `driver` for the
// parts that differ. See acp-session-pool.js and codex-session-pool.js.
//
// The pool is a *cache*, never the source of truth. The session id in
// agent-sessions.json stays authoritative, so whenever the process dies or a
// session is evicted, the next turn re-opens it by resuming that id and behaves
// exactly like the old per-turn model. A dead pool is never worse than no pool.
const DEFAULT_IDLE_MS = 15 * 60 * 1000;
// Live sessions per agent. The cap bounds per-session resource growth while
// still allowing several conversations to run independently.
const DEFAULT_MAX_SESSIONS = 4;
// After asking the agent to cancel, how long to wait for it to wind the turn
// down before dropping the session. Cancel must never hang.
const CANCEL_GRACE_MS = 5000;
// Closing stdin is how these agents are asked to exit; the kill is the backstop.
const KILL_GRACE_MS = 2000;
const MAX_STDERR = 8192;

function cancelledError() {
  const err = new Error('request cancelled');
  err.code = 'AGENT_CANCELLED';
  return err;
}

function sessionLostError(agentKey, cause) {
  const err = new Error((cause && cause.message) || `${agentKey} session ended`);
  err.code = 'AGENT_SESSION_LOST';
  if (cause) err.cause = cause;
  return err;
}

function rpcError(error) {
  const err = new Error((error && error.message) || 'request failed');
  err.code = 'AGENT_REQUEST_FAILED';
  err.data = error && error.data;
  return err;
}

function existingDir(dir) {
  if (!dir) return null;
  try {
    return fs.statSync(dir).isDirectory() ? dir : null;
  } catch (_err) {
    return null;
  }
}

function createStdioAgentPool(options = {}) {
  const agentKey = options.agentKey || 'agent';
  const env = options.env || process.env;
  const now = options.now || (() => Date.now());
  // Explicit options win as given; only operator-supplied env values are
  // clamped to a sane range.
  const idleMs =
    options.idleMs ??
    boundedInteger(
      env.RELAY_AGENT_IDLE_MS,
      DEFAULT_IDLE_MS,
      10 * 1000,
      24 * 60 * 60 * 1000,
    );
  const maxSessions =
    options.maxSessions ??
    boundedInteger(env.RELAY_AGENT_MAX_SESSIONS, DEFAULT_MAX_SESSIONS, 1, 64);
  const turnTimeoutMs = options.turnTimeoutMs || 60 * 60 * 1000;
  const cancelGraceMs = options.cancelGraceMs ?? CANCEL_GRACE_MS;
  const killGraceMs = options.killGraceMs ?? KILL_GRACE_MS;
  // Resolved lazily so an agent that isn't installed fails at turn time with a
  // real message instead of at server boot. `{ cmd, args, env }`: env adds to
  // the server's own environment.
  const resolveCommand = options.command || (() => null);
  const resolveDeleteCommand = options.deleteCommand || null;
  const createDriver = options.driver;

  const live = new Map();
  const slots = createSessionSlots({
    live,
    maxLive: maxSessions,
    idleMs,
    closeEntry: closeSession,
    isBusy: (entry) => entry.turn || entry.background,
    keepAlive: (entry) => {
      // Some CLIs omit a child's failure event. Bound a missing completion by
      // the turn timeout rather than retaining its session forever.
      for (const [id, activity] of entry.backgroundTasks) {
        if (now() - activity >= turnTimeoutMs) entry.backgroundTasks.delete(id);
      }
      return entry.backgroundTasks.size > 0;
    },
    isAlwaysOn: options.isAlwaysOn,
    evictsBefore: (a, b) => {
      const aBusy = a.backgroundTasks.size > 0;
      return aBusy !== (b.backgroundTasks.size > 0)
        ? !aBusy
        : a.lastActivity < b.lastActivity;
    },
  });
  const {
    acquireSlot,
    releaseSlot,
    pumpWaiters,
    clearIdleTimer,
    scheduleIdleClose,
  } = slots;
  let conn = null;
  let connPromise = null;
  let connectionIdleTimer = null;
  let shuttingDown = false;
  // Callers between "released a session" and "about to open one" hold the
  // process, so the swap does not look like the pool going idle.
  let holds = 0;

  // ---------------------------------------------------------------- transport

  function writeFrame(c, frame) {
    if (c.closed) return;
    try {
      c.child.stdin.write(`${JSON.stringify(frame)}\n`);
    } catch (_err) {
      // The exit handler tears the connection down.
    }
  }

  function makeRpc(c) {
    return {
      agentKey,
      caps: c.caps,
      request(method, params) {
        if (c.closed) return Promise.reject(sessionLostError(agentKey));
        const id = c.nextId++;
        return new Promise((resolve, reject) => {
          c.pending.set(id, { resolve, reject });
          writeFrame(c, { jsonrpc: '2.0', id, method, params });
        });
      },
      notify(method, params) {
        writeFrame(c, { jsonrpc: '2.0', method, params });
      },
      reply(id, result) {
        writeFrame(c, { jsonrpc: '2.0', id, result });
      },
      replyError(id, code, message) {
        writeFrame(c, { jsonrpc: '2.0', id, error: { code, message } });
      },
      replayMessage(msg) {
        dispatchMessage(c, msg);
      },
      // Drivers route inbound traffic by the agent's own session id.
      sessionFor(sessionId) {
        return c.sessions.get(sessionId) || null;
      },
      startBackgroundTurn,
      backgroundTaskChanged(entry, taskId, running) {
        if (running) entry.backgroundTasks.set(taskId, now());
        else entry.backgroundTasks.delete(taskId);
        entry.lastActivity = now();
        if (!entry.turn && !entry.background) scheduleIdleClose(entry);
      },
    };
  }

  function handleFrame(c, line) {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (_err) {
      // Agents print the occasional banner or log line to stdout; anything that
      // is not a protocol frame is not ours to interpret.
      return;
    }
    dispatchMessage(c, msg);
  }

  function dispatchMessage(c, msg) {
    if (msg.method === undefined && msg.id !== undefined) {
      const pending = c.pending.get(msg.id);
      if (!pending) return;
      c.pending.delete(msg.id);
      if (msg.error) pending.reject(rpcError(msg.error));
      else pending.resolve(msg.result);
      return;
    }
    if (!msg.method) return;
    try {
      c.driver.handleMessage(msg);
    } catch (err) {
      // A driver or rendering failure must not take the connection down.
      if (!c.messageErrorLogged) {
        c.messageErrorLogged = true;
        console.warn(`[${agentKey}] failed to handle ${msg.method}: ${err.message}`);
      }
    }
  }

  function killChild(c, immediate) {
    try {
      c.child.stdin.end();
    } catch (_err) {
      // Already closed.
    }
    const hardKill = () => {
      try {
        // The agent spawns its own helpers; killing the group is what stops
        // them too, so an evicted session never leaves orphans behind.
        if (c.child.pid && process.platform !== 'win32') {
          process.kill(-c.child.pid, 'SIGKILL');
        } else {
          c.child.kill('SIGKILL');
        }
      } catch (_err) {
        try {
          c.child.kill('SIGKILL');
        } catch (_err2) {
          // Already gone.
        }
      }
    };
    if (immediate) {
      hardKill();
      return;
    }
    const timer = setTimeout(hardKill, killGraceMs);
    if (typeof timer.unref === 'function') timer.unref();
    c.child.once('exit', () => clearTimeout(timer));
  }

  function dropConnection(c, err, immediate) {
    if (c.closed) return;
    c.closed = true;
    if (conn === c) {
      conn = null;
      if (connectionIdleTimer) clearTimeout(connectionIdleTimer);
      connectionIdleTimer = null;
    }
    for (const pending of c.pending.values()) {
      pending.reject(sessionLostError(agentKey, err));
    }
    c.pending.clear();
    // Every session on this process went with it. The stored session id stays
    // authoritative, so the next turn re-opens by resuming it.
    for (const entry of [...c.sessions.values()]) dropEntry(entry, err);
    c.sessions.clear();
    killChild(c, immediate);
  }

  function openConnection() {
    const command = resolveCommand();
    if (!command) {
      return Promise.reject(new Error(`${agentKey} is not installed`));
    }
    const child = spawn(command.cmd, command.args, {
      // Every session carries its own cwd, so the process itself runs somewhere
      // stable: a shared process must not die because one chat's work tree was
      // renamed or deleted.
      cwd: os.homedir(),
      env: command.env ? { ...process.env, ...command.env } : process.env,
      stdio: ['pipe', 'pipe', 'pipe'],
      // Group leader, so killChild can take the agent's helpers down with it.
      detached: process.platform !== 'win32',
    });
    const c = {
      child,
      pending: new Map(),
      sessions: new Map(),
      nextId: 1,
      caps: {},
      closed: false,
      messageErrorLogged: false,
      stderr: '',
      driver: null,
    };
    c.driver = createDriver(makeRpc(c));

    let buffer = '';
    // Decode as UTF-8 at the stream layer so a multi-byte character straddling
    // a chunk boundary is buffered rather than split into replacement chars.
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      buffer += chunk;
      let index;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (line) handleFrame(c, line);
      }
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      // Agents log freely to stderr; keep only the tail, for error messages.
      c.stderr = `${c.stderr}${chunk}`.slice(-MAX_STDERR);
    });
    child.on('error', (err) => dropConnection(c, err));
    child.on('exit', (code, signal) =>
      dropConnection(
        c,
        new Error(
          `${agentKey} exited (${signal ? `signal ${signal}` : `code ${code}`})`,
        ),
      ),
    );

    return Promise.resolve()
      .then(() => c.driver.initialize())
      .then(
        () => c,
        (err) => {
          dropConnection(c, err);
          throw err;
        },
      );
  }

  function ensureConnection() {
    if (connectionIdleTimer) clearTimeout(connectionIdleTimer);
    connectionIdleTimer = null;
    if (conn && !conn.closed) return Promise.resolve(conn);
    if (!connPromise) {
      connPromise = openConnection().then(
        (c) => {
          connPromise = null;
          conn = c;
          return c;
        },
        (err) => {
          connPromise = null;
          throw err;
        },
      );
    }
    return connPromise;
  }

  // ------------------------------------------------------------------ sessions

  function settleTurn(entry, settle, turn = entry.turn) {
    if (!turn) return;
    if (entry.turn === turn) entry.turn = null;
    else if (entry.background === turn) entry.background = null;
    else return;
    clearTimeout(turn.timer);
    if (turn.cancelTimer) clearTimeout(turn.cancelTimer);
    if (turn.detachAbort) turn.detachAbort();
    settle(turn);
  }

  // Forget a session without talking to the agent — used when the process is
  // already gone, or after a graceful close.
  function dropEntry(entry, err) {
    if (entry.closed) return;
    entry.closed = true;
    clearIdleTimer(entry);
    if (live.get(entry.key) === entry) live.delete(entry.key);
    if (entry.sessionId && entry.conn) entry.conn.sessions.delete(entry.sessionId);
    const rejectTurn = (turn) => {
      if (turn.cancelled) return turn.reject(cancelledError());
      const lost = sessionLostError(agentKey, err);
      // Whether the user already saw part of this turn decides if it can be
      // silently re-run.
      lost.emitted = turn.emitted;
      lost.stderr = (entry.conn && entry.conn.stderr) || '';
      return turn.reject(lost);
    };
    settleTurn(entry, rejectTurn);
    settleTurn(entry, rejectTurn, entry.background);
    releaseSlot();
    // The process exists only to host sessions; the last one leaving is what
    // ends the idle life of the agent itself.
    closeIdleConnection();
  }

  function closeIdleConnection() {
    if (connectionIdleTimer) clearTimeout(connectionIdleTimer);
    connectionIdleTimer = null;
    if (!conn || conn.closed) return;
    if (conn.sessions.size > 0 || live.size > 0) return;
    // A caller queued on the cap, or swapping one session for another, is about
    // to use this process; tearing it down here would fail their turn with a
    // lost session — and respawning the CLI is exactly what the pool exists to
    // avoid.
    if (connPromise || slots.waiting || holds > 0) return;
    dropConnection(conn, null, shuttingDown);
  }

  function scheduleIdleConnectionClose() {
    if (connectionIdleTimer) clearTimeout(connectionIdleTimer);
    connectionIdleTimer = setTimeout(closeIdleConnection, idleMs);
    if (typeof connectionIdleTimer.unref === 'function') {
      connectionIdleTimer.unref();
    }
  }

  async function closeSession(entry) {
    if (entry.closed) return;
    const c = entry.conn;
    if (c && !c.closed && entry.sessionId && c.driver.closeSession) {
      try {
        await c.driver.closeSession(entry);
      } catch (_err) {
        // Best effort: the session is being dropped either way.
      }
    }
    dropEntry(entry, null);
  }

  async function spawnEntry(req, retried) {
    // Connect before taking a slot: nothing may await between acquireSlot() and
    // registering the entry, or two concurrent spawns both pass the cap check.
    const c = await ensureConnection();
    await acquireSlot(req.key);
    if (c.closed) {
      // Waiting for a slot takes time, and the process can die (or be closed
      // for going idle) in it. Reconnect rather than fail a turn that never
      // started.
      if (retried) throw sessionLostError(agentKey);
      return spawnEntry(req, true);
    }
    const entry = {
      key: req.key,
      cwd: req.cwd,
      conn: c,
      sessionId: null,
      fixedKey: req.fixedKey || null,
      applied: {},
      turn: null,
      background: null,
      backgroundTasks: new Map(),
      onBackgroundTurn: null,
      onPermission: null,
      idleTimer: null,
      closed: false,
      lastActivity: now(),
    };
    live.set(entry.key, entry);
    try {
      const opened = await c.driver.openSession(req);
      entry.sessionId = opened.sessionId;
      // The caller had a stored id but the agent could not resume it, so this
      // is a different conversation. Reported once, on the turn that finds it.
      entry.startedNew = !!opened.startedNew;
      c.sessions.set(entry.sessionId, entry);
    } catch (err) {
      dropEntry(entry, err);
      throw err;
    }
    return entry;
  }

  function runTurn(entry, req, turnId = null) {
    let turn;
    const pending = new Promise((resolve, reject) => {
      turn = {
        turnId,
        background: turnId !== null,
        onMessage: req.onMessage || (() => {}),
        onPermission: req.onPermission || null,
        emitted: false,
        cancelled: false,
        timer: null,
        cancelTimer: null,
        detachAbort: null,
        resolve,
        reject,
        // The driver-facing pair: settle exactly once, whoever gets there first
        // (the agent, the timeout, a cancel, or the process dying).
        finish(result) {
          settleTurn(entry, (settled) => {
            if (settled.cancelled) settled.reject(cancelledError());
            else settled.resolve(result);
          }, turn);
        },
        fail(err) {
          settleTurn(entry, (settled) => {
            if (settled.cancelled) return settled.reject(cancelledError());
            const lost = sessionLostError(agentKey, err);
            lost.emitted = settled.emitted;
            lost.stderr = entry.conn.stderr || '';
            return settled.reject(lost);
          }, turn);
        },
      };
      if (turn.background) entry.background = turn;
      else entry.turn = turn;
      entry.lastActivity = now();
      clearIdleTimer(entry);

      const stop = () => {
        if (entry.turn !== turn && entry.background !== turn) return;
        turn.cancelled = true;
        try {
          if (entry.conn.driver.cancelTurn) {
            entry.conn.driver.cancelTurn(entry, turn);
          }
        } catch (_err) {
          // Fall through to the grace timer.
        }
        // Cancel is best-effort: if the agent does not wind the turn down
        // promptly, drop the session so cancel is never a hang.
        turn.cancelTimer = setTimeout(() => {
          if (entry.turn === turn || entry.background === turn) {
            dropEntry(entry, new Error('cancelled'));
          }
        }, cancelGraceMs);
        if (typeof turn.cancelTimer.unref === 'function') {
          turn.cancelTimer.unref();
        }
      };
      turn.cancel = stop;

      const signal = req.signal;
      if (signal) {
        // Opening the session took time, and the user may have cancelled in it.
        // An already-aborted signal never fires `abort`, so it is checked here
        // rather than only listened for.
        if (signal.aborted) {
          entry.turn = null;
          reject(cancelledError());
          scheduleIdleClose(entry);
          return;
        }
        const onAbort = () => stop();
        signal.addEventListener('abort', onAbort, { once: true });
        turn.detachAbort = () => signal.removeEventListener('abort', onAbort);
      }

      turn.timer = setTimeout(() => {
        settleTurn(entry, (settled) =>
          settled.resolve({
            stopReason: 'timeout',
            message: `Timed out after ${Math.round(
              turnTimeoutMs / 60000,
            )} minutes and was stopped. Split the task or simplify the prompt.`,
          }),
          turn,
        );
        // The session survives a cancel, so a timed-out turn costs the turn,
        // not the conversation.
        try {
          if (entry.conn.driver.cancelTurn) {
            entry.conn.driver.cancelTurn(entry, turn);
          }
        } catch (_err) {
          // Nothing more to do; the turn is already settled.
        }
      }, turnTimeoutMs);
      if (typeof turn.timer.unref === 'function') turn.timer.unref();

      try {
        if (!turn.background) entry.conn.driver.startTurn(entry, req, turn);
      } catch (err) {
        turn.fail(err);
      }
    }).then(
      (result) => {
        entry.lastActivity = now();
        scheduleIdleClose(entry);
        pumpWaiters();
        const startedNew = entry.startedNew === true;
        entry.startedNew = false;
        return {
          result,
          sessionId: entry.sessionId,
          startedNew,
          stderr: entry.conn.stderr || '',
        };
      },
      (err) => {
        entry.lastActivity = now();
        if (!entry.closed) scheduleIdleClose(entry);
        pumpWaiters();
        throw err;
      },
    );
    turn.done = pending;
    return pending;
  }

  // An agent may start a turn without a user request. Give it the same timeout,
  // cancellation and slot ownership as a requested turn, without turn/start.
  function startBackgroundTurn(entry, turnId, meta) {
    if (entry.closed || entry.background || !turnId) return entry.background;
    let background;
    let handle;
    try {
      handle = entry.onBackgroundTurn?.({
        ...meta,
        interrupt: () => background.cancel(),
      });
    } catch (err) {
      console.warn(`[${agentKey}] failed to start background turn: ${err.message}`);
    }
    const pending = runTurn(entry, {
      onMessage: (event) => handle?.onMessage(event),
      onPermission: entry.onPermission,
    }, turnId);
    background = entry.background;
    pending.then(
      ({ result }) => handle?.finish(result),
      (err) => handle?.fail(err),
    ).catch((err) => {
      console.warn(`[${agentKey}] failed to settle background turn: ${err.message}`);
    });
    return background;
  }

  function waitForBackground(background, signal) {
    return new Promise((resolve, reject) => {
      const onAbort = () => reject(cancelledError());
      const done = () => {
        signal?.removeEventListener('abort', onAbort);
        resolve();
      };
      if (signal?.aborted) return onAbort();
      signal?.addEventListener('abort', onAbort, { once: true });
      background.done.then(done, done);
    });
  }

  // Run one turn on `key`, reusing the live session when there is one.
  async function send(req) {
    // Checked before anything is opened: a turn cancelled before it started
    // must not cost a session slot or a process spawn.
    if (req.signal && req.signal.aborted) throw cancelledError();
    let entry = live.get(req.key);
    // A tool-only background turn may not yet own a chat scope queue. Do not
    // replace its callbacks or start a competing turn on the same thread.
    while (entry && entry.background) {
      await waitForBackground(entry.background, req.signal);
      if (req.signal && req.signal.aborted) throw cancelledError();
      entry = live.get(req.key);
    }
    // The live session knows the current id (a brand-new session gets one the
    // caller has not stored yet), so prefer it over the caller's.
    const resumeId = (entry && entry.sessionId) || req.resumeId || null;
    // cwd, and any setting the agent fixes when a session is opened, need a
    // fresh session — which still resumes the same conversation.
    const stale =
      !!entry &&
      (entry.closed ||
        entry.conn.closed ||
        entry.cwd !== req.cwd ||
        entry.fixedKey !== (req.fixedKey || null));
    const warm = !!entry && !stale;
    if (stale) {
      holds += 1;
      try {
        await closeSession(entry);
        entry = await spawnEntry({ ...req, resumeId });
      } finally {
        holds -= 1;
        closeIdleConnection();
      }
    } else if (!entry) {
      entry = await spawnEntry({ ...req, resumeId });
    }
    if (entry.conn.driver.applySettings) {
      await entry.conn.driver.applySettings(entry, req);
    }
    // Idle monitoring can start a background turn while settings RPCs await.
    while (entry.background) {
      await waitForBackground(entry.background, req.signal);
    }
    entry.onBackgroundTurn = req.onBackgroundTurn || null;
    entry.onPermission = req.onPermission || null;
    try {
      return await runTurn(entry, req);
    } catch (err) {
      const lost = err && err.code === 'AGENT_SESSION_LOST' && !err.emitted;
      if (!warm || !lost) throw err;
      // A warm session died before producing anything. Fall back to the cold
      // path so a stale pooled session is never worse than no pool at all.
      const fresh = await spawnEntry({ ...req, resumeId });
      if (fresh.conn.driver.applySettings) {
        await fresh.conn.driver.applySettings(fresh, req);
      }
      while (fresh.background) {
        await waitForBackground(fresh.background, req.signal);
      }
      fresh.onBackgroundTurn = req.onBackgroundTurn || null;
      fresh.onPermission = req.onPermission || null;
      return runTurn(fresh, req);
    }
  }

  // Run a connection-level driver method without opening a conversation. This
  // is used for protocol-native metadata such as Codex `account/read`. It shares
  // the same process as turns and keeps an otherwise-empty connection warm for
  // the normal idle window, so a status check never creates a parallel agent.
  async function callDriver(method, ...args) {
    holds += 1;
    let c = null;
    try {
      c = await ensureConnection();
      const fn = c.driver && c.driver[method];
      if (typeof fn !== 'function') {
        throw new Error(`${agentKey} driver does not support ${method}`);
      }
      return await fn(...args);
    } finally {
      holds -= 1;
      if (c && !c.closed && c.sessions.size === 0 && live.size === 0) {
        scheduleIdleConnectionClose();
      }
    }
  }

  function runDeleteCommand(sessionId, cwd) {
    const command = resolveDeleteCommand && resolveDeleteCommand(sessionId);
    if (!command) return Promise.resolve(false);
    return new Promise((resolve) => {
      const child = spawn(command.cmd, command.args, {
        // Deleting a chat often means its work tree is gone too, and spawning
        // into a missing cwd fails before the CLI ever runs.
        cwd: existingDir(cwd) || os.homedir(),
        env: process.env,
        stdio: 'ignore',
      });
      child.on('error', () => resolve(false));
      child.on('exit', (code) => resolve(code === 0));
    });
  }

  // Drop the live session for a scope. With `purge`, also make a best-effort
  // request to delete the agent's stored transcript.
  async function forget(key, opts = {}) {
    const entry = live.get(key);
    const sessionId = opts.sessionId || (entry && entry.sessionId) || null;
    const cwd = opts.cwd || (entry && entry.cwd) || undefined;
    if (entry) await closeSession(entry);
    if (!opts.purge || !sessionId) return false;
    // Some protocols can delete in-band; the rest shell out to their CLI.
    if (conn && !conn.closed && conn.driver.deleteSession) {
      try {
        return await conn.driver.deleteSession(sessionId);
      } catch (_err) {
        return false;
      }
    }
    if (resolveDeleteCommand) return runDeleteCommand(sessionId, cwd);
    // No live process and nothing to shell out to: open one just to delete.
    try {
      const c = await ensureConnection();
      const deleted = c.driver.deleteSession
        ? await c.driver.deleteSession(sessionId)
        : false;
      closeIdleConnection();
      return deleted;
    } catch (_err) {
      return false;
    }
  }

  async function shutdown() {
    shuttingDown = true;
    if (connectionIdleTimer) clearTimeout(connectionIdleTimer);
    connectionIdleTimer = null;
    for (const entry of [...live.values()]) dropEntry(entry, null);
    live.clear();
    if (conn) dropConnection(conn, null, true);
  }

  function stats() {
    return {
      live: live.size,
      maxSessions,
      idleMs,
      waiting: slots.waiting,
      connected: !!(conn && !conn.closed),
      keys: [...live.keys()],
    };
  }

  return { send, callDriver, forget, shutdown, stats };
}

module.exports = { createStdioAgentPool };
