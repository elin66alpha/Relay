'use strict';

// Persistent Claude sessions.
//
// Relay used to run one `claude --print --resume <id>` process per turn: the
// process died the moment the turn ended, so anything it started in the
// background (watchers, servers, long-running tasks) died with it, and every
// turn paid the cold-start cost of booting the CLI, its MCP servers, and the
// stored transcript.
//
// This pool keeps one live `query()` per scope instead, using the Agent SDK's
// streaming-input mode — the same thing a terminal session is: one process that
// stays open and takes message after message on stdin.
//
// The pool is a *cache*, never the source of truth. The session id in
// agent-sessions.json stays authoritative, so whenever a live process is
// missing, evicted, or dies, the next turn cold-starts with `resume: <id>` and
// behaves exactly like the old per-turn model. That keeps the failure mode of
// "no warm process" identical to Relay's previous behaviour rather than a new
// one.
const crypto = require('crypto');

const DEFAULT_IDLE_MS = 15 * 60 * 1000;
const DEFAULT_MAX_LIVE = 3;
// After an interrupt, how long to wait for the CLI to wind the turn down
// cleanly before falling back to killing the process. Interrupt is the whole
// point of keeping the session alive, but cancel must never hang on it.
const INTERRUPT_GRACE_MS = 5000;

function positiveInt(value, fallbackValue, min, max) {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) && parsed >= min && parsed <= max
    ? parsed
    : fallbackValue;
}

function cancelledError() {
  const err = new Error('request cancelled');
  err.code = 'AGENT_CANCELLED';
  return err;
}

function sessionLostError(cause) {
  const err = new Error(
    cause && cause.message ? cause.message : 'claude session ended',
  );
  err.code = 'CLAUDE_SESSION_LOST';
  if (cause) err.cause = cause;
  return err;
}

// Claude also runs turns nobody sent: when a background task (a background
// subagent, Monitor, or shell) finishes, and on resume after one was cut off.
// Those end in a result too, so a result answers the turn only when it names
// that turn's message. The CLI stamps it even when the message was folded into
// a turn of its own; older CLIs stamp nothing, and then a turn they started
// themselves is told apart by its origin.
//
// A turn Claude starts while the session is idle is a *background turn*: it
// opens on its first assistant message and closes on the next result. It is
// handed to the scope's `onBackgroundTurn`, and owns the stream until that
// result, since the CLI runs one turn at a time.
function answersTurn(turn, result) {
  if (result.user_message_uuid) return result.user_message_uuid === turn.uuid;
  return !result.origin || result.origin.kind === 'human';
}

const TASK_ENDED = new Set(['completed', 'failed', 'killed']);

// Background tasks the CLI is still running for this session. While any is,
// the session is not idle: closing it would kill that work.
function trackTask(entry, message) {
  if (!message || message.type !== 'system' || !message.task_id) return false;
  const ended =
    message.subtype === 'task_notification' ||
    (message.subtype === 'task_updated' &&
      TASK_ENDED.has(message.patch && message.patch.status));
  if (message.subtype === 'task_started') entry.tasks.add(message.task_id);
  else if (ended) return entry.tasks.delete(message.task_id);
  return false;
}

// Eviction order: sessions without background work first, then the least
// recently used.
function evictsBefore(a, b) {
  const aBusy = a.tasks.size > 0;
  if (aBusy !== (b.tasks.size > 0)) return !aBusy;
  return a.lastActivity < b.lastActivity;
}

// stdin for one live session: an async iterable the SDK drains, that we push
// user messages into as turns arrive. Staying un-ended is what keeps the CLI
// process alive between turns.
function createInputQueue() {
  const pending = [];
  const waiters = [];
  let ended = false;
  return {
    // Returns the message's uuid, which the CLI echoes on the result that
    // answers it.
    push(text) {
      const message = {
        type: 'user',
        uuid: crypto.randomUUID(),
        message: { role: 'user', content: String(text) },
        parent_tool_use_id: null,
      };
      const waiter = waiters.shift();
      if (waiter) waiter({ value: message, done: false });
      else pending.push(message);
      return message.uuid;
    },
    end() {
      if (ended) return;
      ended = true;
      while (waiters.length) waiters.shift()({ value: undefined, done: true });
    },
    [Symbol.asyncIterator]() {
      return {
        next() {
          if (pending.length) {
            return Promise.resolve({ value: pending.shift(), done: false });
          }
          if (ended) return Promise.resolve({ value: undefined, done: true });
          return new Promise((resolve) => waiters.push(resolve));
        },
      };
    },
  };
}

function createClaudeSessionPool(options = {}) {
  const env = options.env || process.env;
  // Explicit options win as given; only operator-supplied env values are
  // clamped to a sane range.
  const idleMs =
    options.idleMs ??
    positiveInt(
      env.RELAY_CLAUDE_IDLE_MS,
      DEFAULT_IDLE_MS,
      10 * 1000,
      24 * 60 * 60 * 1000,
    );
  const maxLive =
    options.maxLive ??
    positiveInt(env.RELAY_CLAUDE_MAX_LIVE, DEFAULT_MAX_LIVE, 1, 64);
  const now = options.now || (() => Date.now());
  const turnTimeoutMs = options.turnTimeoutMs || 60 * 60 * 1000;
  const interruptGraceMs = options.interruptGraceMs ?? INTERRUPT_GRACE_MS;

  // The SDK is ESM-only and the server is CommonJS, so it is loaded lazily via
  // dynamic import (works on every supported Node) and cached.
  let sdkPromise = null;
  function loadSdk() {
    if (options.sdk) return Promise.resolve(options.sdk);
    if (!sdkPromise) sdkPromise = import('@anthropic-ai/claude-agent-sdk');
    return sdkPromise;
  }

  const live = new Map();
  const slotWaiters = [];

  function releaseSlot() {
    const waiter = slotWaiters.shift();
    if (waiter) waiter();
  }

  // A finished turn frees the session for eviction but not the slot: the
  // process stays live. Group chats summon several members at once, so without
  // this a caller waiting on the cap would never be woken by a turn ending —
  // only by an unrelated eviction.
  function pumpWaiters() {
    if (!slotWaiters.length) return;
    const victim = lruIdleEntry();
    if (victim) closeEntry(victim).catch(() => {});
  }

  function clearIdleTimer(entry) {
    if (entry.idleTimer) clearTimeout(entry.idleTimer);
    entry.idleTimer = null;
  }

  function scheduleIdleClose(entry) {
    clearIdleTimer(entry);
    if (entry.closed) return;
    entry.idleTimer = setTimeout(() => {
      if (entry.turn || entry.background) return;
      // Background work keeps the session alive; check again later.
      if (entry.tasks.size) return scheduleIdleClose(entry);
      closeEntry(entry).catch(() => {});
    }, idleMs);
    if (typeof entry.idleTimer.unref === 'function') entry.idleTimer.unref();
  }

  function settleTurn(entry, settle) {
    const turn = entry.turn;
    if (!turn) return;
    entry.turn = null;
    clearTimeout(turn.timer);
    if (turn.detachAbort) turn.detachAbort();
    settle(turn);
  }

  async function closeEntry(entry, err) {
    if (entry.closed) return;
    entry.closed = true;
    clearIdleTimer(entry);
    if (live.get(entry.key) === entry) live.delete(entry.key);
    settleTurn(entry, (turn) => {
      if (turn.cancelled) return turn.reject(cancelledError());
      const lost = sessionLostError(err);
      // Whether the user already saw part of this turn decides if it can be
      // silently re-run.
      lost.emitted = turn.emitted;
      return turn.reject(lost);
    });
    settleBackground(entry, (handle) => handle.fail(sessionLostError(err)));
    try {
      entry.input.end();
    } catch (_err) {
      // Already ended.
    }
    try {
      entry.query.close();
    } catch (_err) {
      // Already gone.
    }
    releaseSlot();
  }

  // Evict the least recently used session that is not mid-turn, preferring
  // one with no background work: that is only cut off when nothing else can
  // make room.
  function lruIdleEntry() {
    let victim = null;
    for (const entry of live.values()) {
      if (entry.turn || entry.background || entry.closed) continue;
      if (!victim || evictsBefore(entry, victim)) victim = entry;
    }
    return victim;
  }

  async function acquireSlot() {
    // The cap covers every live CLI process the pool owns. When every session
    // is mid-turn there is nothing safe to evict, so the caller waits for a
    // slot rather than the pool quietly exceeding its own memory budget.
    while (live.size >= maxLive) {
      const victim = lruIdleEntry();
      if (victim) {
        await closeEntry(victim);
        continue;
      }
      await new Promise((resolve) => slotWaiters.push(resolve));
    }
  }

  function startBackground(entry) {
    const notices = entry.notices;
    entry.notices = [];
    let handle = null;
    try {
      if (entry.onBackgroundTurn) handle = entry.onBackgroundTurn({ notices });
    } catch (_err) {
      handle = null;
    }
    clearIdleTimer(entry);
    // Tracked even with nobody to hand it to, so its messages never leak into
    // the next turn.
    entry.background = {
      handle: handle || { onMessage() {}, finish() {}, fail() {} },
      timer: setTimeout(() => {
        closeEntry(entry, new Error('background turn timed out')).catch(() => {});
      }, turnTimeoutMs),
    };
    if (typeof entry.background.timer.unref === 'function') {
      entry.background.timer.unref();
    }
  }

  function settleBackground(entry, settle) {
    const background = entry.background;
    if (!background) return;
    entry.background = null;
    clearTimeout(background.timer);
    try {
      settle(background.handle);
    } catch (_err) {
      // The listener's failure must not take the session down.
    }
    if (!entry.closed && !entry.turn) scheduleIdleClose(entry);
    pumpWaiters();
  }

  function routeMessage(entry, message) {
    if (message && message.session_id) entry.sessionId = message.session_id;
    entry.lastActivity = now();
    // The last background task ending starts a full idle window, so the turn
    // the CLI runs on its result is not cut short.
    if (trackTask(entry, message) && !entry.turn && !entry.background) {
      scheduleIdleClose(entry);
    }
    if (!message) return;
    const turn = entry.turn;
    // A background turn keeps everything up to its own result, even once a
    // turn has been pushed behind it.
    if (
      entry.background &&
      !(turn && message.type === 'result' && message.user_message_uuid === turn.uuid)
    ) {
      if (message.type === 'result') {
        settleBackground(entry, (handle) => handle.finish(message));
      } else {
        try {
          entry.background.handle.onMessage(message);
        } catch (_err) {
          // A rendering failure must not take the session down.
        }
      }
      return;
    }
    if (!turn) {
      // What woke Claude up arrives before the turn it runs on it.
      if (message.type === 'system' && message.subtype === 'task_notification') {
        entry.notices.push(message);
      } else if (message.type === 'assistant') {
        startBackground(entry);
        routeMessage(entry, message);
      }
      return;
    }
    if (message.type === 'result') {
      if (!answersTurn(turn, message)) return;
      settleTurn(entry, (settled) => {
        if (settled.cancelled) settled.reject(cancelledError());
        else settled.resolve(message);
      });
      return;
    }
    // Only assistant messages reach the user, and they are what makes a silent
    // retry unsafe.
    if (message.type === 'assistant') turn.emitted = true;
    try {
      turn.onMessage(message);
    } catch (_err) {
      // A rendering failure must not take the session down.
    }
  }

  async function spawnEntry(request) {
    // Load before taking a slot: nothing may await between acquireSlot() and
    // registering the entry, or two concurrent spawns both pass the cap check.
    const { query } = await loadSdk();
    await acquireSlot();
    const input = createInputQueue();
    const entry = {
      key: request.key,
      cwd: request.cwd,
      optionsKey: request.optionsKey,
      sessionId: request.resumeId || null,
      tasks: new Set(),
      notices: [],
      background: null,
      onBackgroundTurn: request.onBackgroundTurn || null,
      input,
      query: null,
      turn: null,
      idleTimer: null,
      closed: false,
      lastActivity: now(),
    };
    // Reserve the slot before the first await so two concurrent callers can't
    // both slip past the cap.
    live.set(entry.key, entry);
    try {
      entry.query = query({
        prompt: input,
        options: {
          ...request.sdkOptions,
          cwd: request.cwd,
          // Match what the plain CLI does: Claude Code's own system prompt and
          // the user's on-disk settings, CLAUDE.md, and MCP servers.
          systemPrompt: { type: 'preset', preset: 'claude_code' },
          includePartialMessages: true,
          ...(request.resumeId ? { resume: request.resumeId } : {}),
          ...(request.executablePath
            ? { pathToClaudeCodeExecutable: request.executablePath }
            : {}),
          stderr: (data) => {
            entry.stderr = `${entry.stderr || ''}${data}`.slice(-8192);
          },
        },
      });
    } catch (err) {
      await closeEntry(entry, err);
      throw err;
    }
    entry.reader = (async () => {
      try {
        for await (const message of entry.query) routeMessage(entry, message);
        await closeEntry(entry);
      } catch (err) {
        await closeEntry(entry, err);
      }
    })();
    return entry;
  }

  function runTurn(entry, request) {
    return new Promise((resolve, reject) => {
      const turn = {
        uuid: null,
        onMessage: request.onMessage || (() => {}),
        emitted: false,
        cancelled: false,
        resolve,
        reject,
        timer: null,
        detachAbort: null,
      };
      entry.turn = turn;
      entry.lastActivity = now();
      // Notices nobody acted on yet are folded into this turn by the CLI.
      entry.notices = [];
      clearIdleTimer(entry);

      const stop = (reason) => {
        if (entry.turn !== turn) return;
        turn.cancelled = true;
        Promise.resolve()
          .then(() => entry.query.interrupt())
          .catch(() => {})
          .then(() => {
            // Interrupt is best-effort: if the CLI does not wind the turn down
            // promptly, drop the whole session so cancel is never a hang.
            setTimeout(() => {
              if (entry.turn === turn) closeEntry(entry, reason).catch(() => {});
            }, interruptGraceMs).unref?.();
          });
      };

      const signal = request.signal;
      if (signal) {
        if (signal.aborted) {
          entry.turn = null;
          reject(cancelledError());
          scheduleIdleClose(entry);
          return;
        }
        const onAbort = () => stop(new Error('cancelled'));
        signal.addEventListener('abort', onAbort, { once: true });
        turn.detachAbort = () => signal.removeEventListener('abort', onAbort);
      }

      turn.timer = setTimeout(() => {
        settleTurn(entry, (settled) => {
          settled.resolve({
            type: 'result',
            subtype: 'timeout',
            is_error: true,
            result: `Timed out after ${Math.round(
              turnTimeoutMs / 60000,
            )} minutes and was stopped. Split the task or simplify the prompt.`,
          });
        });
        closeEntry(entry, new Error('turn timed out')).catch(() => {});
      }, turnTimeoutMs);
      if (typeof turn.timer.unref === 'function') turn.timer.unref();

      try {
        turn.uuid = entry.input.push(request.prompt);
      } catch (err) {
        settleTurn(entry, (settled) => settled.reject(err));
      }
    }).then(
      (result) => {
        entry.lastActivity = now();
        scheduleIdleClose(entry);
        pumpWaiters();
        return { result, sessionId: entry.sessionId, stderr: entry.stderr || '' };
      },
      (err) => {
        entry.lastActivity = now();
        if (!entry.closed) scheduleIdleClose(entry);
        pumpWaiters();
        throw err;
      },
    );
  }

  // Run one turn on `key`, reusing the live session when there is one.
  async function send(request) {
    let entry = live.get(request.key);
    // The live session knows the current id (a brand-new or forked session gets
    // one the caller has not stored yet), so prefer it over the caller's.
    let resumeId = (entry && entry.sessionId) || request.resumeId;
    if (
      entry &&
      (entry.closed ||
        entry.cwd !== request.cwd ||
        entry.optionsKey !== request.optionsKey)
    ) {
      // Model / effort / permission / fast-mode changes are fixed at spawn
      // time, so a settings change restarts the process and resumes into the
      // same conversation. The user sees continuity; the flags are re-applied.
      await closeEntry(entry);
      entry = null;
    }
    const warm = !!entry;
    // A restart resumes the conversation it replaced; the live session's id
    // wins over the caller's, which may be one turn behind.
    if (!entry) entry = await spawnEntry({ ...request, resumeId });
    // The latest turn says where a later background turn is delivered.
    entry.onBackgroundTurn = request.onBackgroundTurn || null;
    try {
      return await runTurn(entry, request);
    } catch (err) {
      const lost = err && err.code === 'CLAUDE_SESSION_LOST' && !err.emitted;
      if (!warm || !lost) throw err;
      // A warm session died before producing anything. Fall back to the cold
      // path so a stale pooled process is never worse than no pool at all.
      const fresh = await spawnEntry({ ...request, resumeId });
      return runTurn(fresh, request);
    }
  }

  // Drop the live process for a scope. With `purge`, also make a best-effort
  // request to delete the stored transcript.
  async function forget(key, opts = {}) {
    const entry = live.get(key);
    const sessionId = opts.sessionId || (entry && entry.sessionId) || null;
    const cwd = opts.cwd || (entry && entry.cwd) || undefined;
    if (entry) await closeEntry(entry);
    if (!opts.purge || !sessionId) return false;
    try {
      const { deleteSession } = await loadSdk();
      await deleteSession(sessionId, cwd ? { dir: cwd } : undefined);
      return true;
    } catch (_err) {
      // The transcript may already be gone; the scope is dropped either way.
      return false;
    }
  }

  async function shutdown() {
    await Promise.all([...live.values()].map((entry) => closeEntry(entry)));
  }

  function stats() {
    return {
      live: live.size,
      maxLive,
      idleMs,
      waiting: slotWaiters.length,
      keys: [...live.keys()],
    };
  }

  return { send, forget, shutdown, stats };
}

module.exports = { createClaudeSessionPool };
