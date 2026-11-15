'use strict';

const { createStdioAgentPool } = require('./stdio-agent-pool');

// The ACP (Agent Client Protocol) driver, used by opencode, hermes, agy, and cursor:
// each ships an `acp` subcommand that speaks it on stdio. stdio-agent-pool.js
// owns the process, the wire and the session cap; this file is only the protocol.
// Cursor-only options, unset for opencode and hermes so their handshake stays
// the same: `authMethod` (Cursor rejects session/new until `cursor_login`),
// `clientMeta` (sent as clientCapabilities._meta; Cursor's
// `parameterizedModelPicker` exposes effort and speed as config options) and
// `modelsMethod` (the request that lists models without opening a session).
//
// ACP turns are request/response — `session/prompt` resolves when the turn ends
// — and settings apply to a live session with no restart, which is why nothing
// here is fixed at open time.
const PROTOCOL_VERSION = 1;
const DEFAULT_TRAJECTORY_POLL_MS = 1000;
const TRAJECTORY_RETRY_MS = 5000;

function systemMessageNotice(step) {
  const sys = step && step.systemMessage;
  if (!sys) return null;
  const raw = String(sys.summary || sys.message || sys.text || '').trim();
  if (!raw) return null;
  const line = raw
    .split(/\r?\n/)
    .map((part) => part.trim())
    .find((part) => part && !part.startsWith('<'));
  if (!line) return null;
  const summary = line
    .replace(/"[^"]*\/([^"/]+)"/g, '$1')
    .replace(/:\s*$/, '')
    .trim();
  return summary ? { summary } : null;
}

function isLowPrioritySystemStep(step) {
  return !!(
    step &&
    (step.type === 'CORTEX_STEP_TYPE_SYSTEM_MESSAGE' || step.systemMessage) &&
    !step.plannerResponse &&
    !(step.requestedInteraction && step.status === 'CORTEX_STEP_STATUS_WAITING') &&
    step.systemMessage &&
    step.systemMessage.priority === 'MESSAGE_PRIORITY_LOW'
  );
}

function isSystemOnlyStep(step) {
  return !!(
    step &&
    (step.type === 'CORTEX_STEP_TYPE_SYSTEM_MESSAGE' || step.systemMessage) &&
    !step.plannerResponse &&
    !step.requestedInteraction
  );
}

function stepStillActive(step) {
  const status = step && step.status;
  return (
    status === 'CORTEX_STEP_STATUS_RUNNING' ||
    status === 'CORTEX_STEP_STATUS_WAITING' ||
    status === 'CORTEX_STEP_STATUS_PENDING'
  );
}

function interactionTitle(step) {
  const ri = (step && step.requestedInteraction) || {};
  return (
    (ri.runCommand &&
      (ri.runCommand.commandLine || ri.runCommand.proposedCommandLine)) ||
    (ri.filePermission && ri.filePermission.absolutePathUri) ||
    (ri.permission && (ri.permission.title || ri.permission.toolName)) ||
    (step &&
      step.metadata &&
      step.metadata.toolCall &&
      step.metadata.toolCall.name) ||
    'tool call'
  );
}

function createAcpDriver(rpc, options = {}) {
  const authMethod = options.authMethod || null;
  const skipQuestions = options.skipQuestions === true;
  const clientMeta = options.clientMeta || null;
  const modelsMethod = options.modelsMethod || null;
  const trajectory = options.trajectory || null;
  const pollMs =
    (trajectory && Number(trajectory.pollMs)) || DEFAULT_TRAJECTORY_POLL_MS;

  function stopTrajectoryWatch(entry) {
    if (!entry || !entry.trajectoryTimer) return;
    clearTimeout(entry.trajectoryTimer);
    entry.trajectoryTimer = null;
  }

  async function syncTrajectoryBaseline(entry) {
    if (!trajectory || !trajectory.readTrajectory || entry.closed) return;
    try {
      const found = await trajectory.readTrajectory(entry.sessionId, {
        port: entry.trajectoryPort,
      });
      if (!found || !found.body || !found.body.trajectory) return;
      entry.trajectoryPort = found.port || entry.trajectoryPort;
      const steps = Array.isArray(found.body.trajectory.steps)
        ? found.body.trajectory.steps
        : [];
      entry.trajectoryBaseline = steps.length;
      entry.trajectoryLastSteps = steps.length;
    } catch (_err) {
      // Best effort: the idle watcher can establish the baseline on its next poll.
    }
  }

  function scheduleTrajectoryWatch(entry, delayMs = pollMs) {
    if (!trajectory || !trajectory.readTrajectory || entry.closed || entry.turn) {
      return;
    }
    stopTrajectoryWatch(entry);
    entry.trajectoryTimer = setTimeout(() => {
      entry.trajectoryTimer = null;
      pollTrajectory(entry);
    }, delayMs);
    if (typeof entry.trajectoryTimer.unref === 'function') {
      entry.trajectoryTimer.unref();
    }
  }

  async function pollTrajectory(entry) {
    if (
      !trajectory ||
      !trajectory.readTrajectory ||
      entry.closed ||
      entry.turn ||
      entry.trajectoryPolling
    ) {
      return;
    }
    entry.trajectoryPolling = true;
    let nextPollMs = pollMs;
    try {
      const found = await trajectory.readTrajectory(entry.sessionId, {
        port: entry.trajectoryPort,
      });
      if (
        !found ||
        !found.body ||
        !found.body.trajectory
      ) {
        nextPollMs = Math.max(pollMs, TRAJECTORY_RETRY_MS);
        return;
      }
      if (entry.closed || entry.turn) return;
      entry.trajectoryPort = found.port || entry.trajectoryPort;
      const body = found.body;
      const steps = Array.isArray(body.trajectory.steps)
        ? body.trajectory.steps
        : [];
      entry.trajectoryLastSteps = steps.length;
      if (entry.trajectoryBaseline == null) {
        entry.trajectoryBaseline = steps.length;
        return;
      }
      if (steps.length <= entry.trajectoryBaseline && !entry.background) {
        return;
      }
      const startIndex = entry.trajectoryState
        ? entry.trajectoryState.startIndex
        : entry.trajectoryBaseline;
      const newSteps = steps.slice(startIndex);
      const running =
        body.status === 'CASCADE_RUN_STATUS_RUNNING' ||
        newSteps.some(stepStillActive);
      if (!entry.background) {
        if (!running && newSteps.every(isLowPrioritySystemStep)) {
          entry.trajectoryBaseline = steps.length;
          return;
        }
        if (!running && newSteps.every(isSystemOnlyStep)) {
          return;
        }
        const notices = newSteps.map(systemMessageNotice).filter(Boolean);
        rpc.startBackgroundTurn(entry, `agy-bg-${startIndex}`, { notices });
        entry.trajectoryState = {
          startIndex,
          emittedTextLen: new Map(),
          stepFullTexts: new Map(),
          emittedTools: new Set(),
          handledInteractions: new Set(),
        };
        if (!entry.replayedToolCallIds) entry.replayedToolCallIds = new Set();
        if (!entry.replayedTexts) entry.replayedTexts = [];
      }
      const turn = entry.background;
      const state = entry.trajectoryState;
      if (!turn || !state) return;

      for (let i = state.startIndex; i < steps.length; i += 1) {
        const step = steps[i] || {};
        const pr = step.plannerResponse;
        if (pr) {
          if (Array.isArray(pr.toolCalls)) {
            for (const tc of pr.toolCalls) {
              const rawId = tc && (tc.id || tc.toolCallId);
              const toolId = rawId || `${i}:${(tc && tc.name) || 'tool'}`;
              if (!state.emittedTools.has(toolId)) {
                state.emittedTools.add(toolId);
                if (rawId) entry.replayedToolCallIds.add(rawId);
                turn.onMessage({
                  sessionUpdate: 'tool_call',
                  toolCallId: toolId,
                  title: (tc && (tc.title || tc.name)) || 'tool',
                });
              }
            }
          }
          const text = typeof pr.response === 'string' ? pr.response : '';
          const prev = state.emittedTextLen.get(i) || 0;
          if (text.length > prev) {
            const delta = text.slice(prev);
            state.emittedTextLen.set(i, text.length);
            state.stepFullTexts.set(i, text);
            turn.emitted = true;
            turn.onMessage({
              sessionUpdate: 'agent_message_chunk',
              messageId: pr.messageId || `step-${i}`,
              content: { type: 'text', text: delta },
            });
          }
        }
        if (
          step.status === 'CORTEX_STEP_STATUS_WAITING' &&
          step.requestedInteraction &&
          !state.handledInteractions.has(i) &&
          trajectory.answerInteraction
        ) {
          state.handledInteractions.add(i);
          const ri = step.requestedInteraction;
          let approve = false;
          if (!ri.askQuestion) {
            try {
              approve = !!(
                turn.onPermission &&
                turn.onPermission({ title: interactionTitle(step) })
              );
            } catch (_err) {
              approve = false;
            }
          }
          await trajectory.answerInteraction(
            entry.trajectoryPort,
            entry.sessionId,
            {
              trajectoryId: body.trajectory.trajectoryId,
              stepIndex: i,
              requestedInteraction: ri,
            },
            approve,
          );
          if (entry.closed || entry.turn || entry.background !== turn) return;
        }
      }

      if (!running && entry.background === turn) {
        entry.replayedTexts.push(...state.stepFullTexts.values());
        if (trajectory.contextFromTrajectory) {
          const ctx = trajectory.contextFromTrajectory(body);
          if (ctx) {
            turn.onMessage({
              sessionUpdate: 'usage_update',
              used: ctx.used,
              size: ctx.size,
            });
          }
        }
        entry.trajectoryBaseline = steps.length;
        entry.trajectoryState = null;
        turn.finish({ stopReason: 'end_turn' });
      }
    } catch (_err) {
      // Transient HTTP errors to the local language server are retried next poll.
      nextPollMs = Math.max(pollMs, TRAJECTORY_RETRY_MS);
    } finally {
      entry.trajectoryPolling = false;
      if (!entry.closed && !entry.turn) scheduleTrajectoryWatch(entry, nextPollMs);
    }
  }

  return {
    async initialize() {
      const init = await rpc.request('initialize', {
        protocolVersion: PROTOCOL_VERSION,
        // Relay does not proxy the filesystem or terminals: the agent runs on
        // the same machine, so it uses its own.
        clientCapabilities: {
          fs: { readTextFile: false, writeTextFile: false },
          terminal: false,
          ...(clientMeta ? { _meta: clientMeta } : {}),
        },
      });
      const caps = (init && init.agentCapabilities) || {};
      const sessionCaps = caps.sessionCapabilities || {};
      rpc.caps.loadSession = !!caps.loadSession;
      // Hermes advertises no close, so its evicted sessions are only dropped.
      rpc.caps.close = !!sessionCaps.close;
      if (authMethod) {
        await rpc.request('authenticate', { methodId: authMethod });
      }
    },

    async openSession(req) {
      if (req.resumeId && rpc.caps.loadSession) {
        try {
          await rpc.request('session/load', {
            sessionId: req.resumeId,
            cwd: req.cwd,
            mcpServers: [],
          });
          return { sessionId: req.resumeId, startedNew: false };
        } catch (_err) {
          // A stored session the agent no longer has. Start a fresh one rather
          // than failing the turn — the same recovery the per-turn runner did
          // when `--session` was rejected.
        }
      }
      const created = await rpc.request('session/new', {
        cwd: req.cwd,
        mcpServers: [],
      });
      const sessionId = created && created.sessionId;
      if (!sessionId) throw new Error(`${rpc.agentKey} returned no session id`);
      return { sessionId, startedNew: !!req.resumeId };
    },

    closeSession(entry) {
      stopTrajectoryWatch(entry);
      if (!rpc.caps.close) return Promise.resolve();
      return rpc.request('session/close', { sessionId: entry.sessionId });
    },

    // Model and mode changes are hot in ACP: they apply to the live session
    // with no restart, unlike the Claude pool where they are fixed at spawn.
    // An agent that rejects a value keeps running on its own default rather
    // than failing the user's turn over a setting.
    applySettings(entry, req) {
      const set = async (field, method, key) => {
        const value = req[field];
        if (!value || entry.applied[field] === value || entry.closed) return;
        try {
          await rpc.request(method, { sessionId: entry.sessionId, [key]: value });
          entry.applied[field] = value;
        } catch (_err) {
          // Left on the agent's own default.
        }
      };
      // `configOptions` is an ordered [configId, value] list. Order matters:
      // choosing a model resets its parameters, so the model goes first and a
      // change re-applies everything after it.
      const setConfig = async () => {
        const list = req.configOptions || [];
        const key = JSON.stringify(list);
        if (!list.length || entry.applied.configOptions === key || entry.closed) return;
        try {
          for (const [configId, value] of list) {
            await rpc.request('session/set_config_option', {
              sessionId: entry.sessionId,
              configId,
              value,
            });
          }
          entry.applied.configOptions = key;
        } catch (_err) {
          // Left on the agent's own default.
        }
      };
      return Promise.all([
        set('modelId', 'session/set_model', 'modelId'),
        set('modeId', 'session/set_mode', 'modeId'),
        setConfig(),
      ]);
    },

    // The model catalog, without opening a session; null when the agent has
    // no such request.
    async listModels() {
      if (!modelsMethod) return null;
      const result = await rpc.request(modelsMethod, {});
      return (result && result.models) || null;
    },

    startTurn(entry, req, turn) {
      stopTrajectoryWatch(entry);
      rpc
        .request('session/prompt', {
          sessionId: entry.sessionId,
          prompt: [{ type: 'text', text: String(req.prompt) }],
        })
        .then(
          async (result) => {
            if (trajectory) await syncTrajectoryBaseline(entry);
            turn.finish(result || { stopReason: 'end_turn' });
            if (trajectory && !entry.closed) scheduleTrajectoryWatch(entry);
          },
          (err) => {
            turn.fail(err);
            if (trajectory && !entry.closed) scheduleTrajectoryWatch(entry);
          },
        );
    },

    cancelTurn(entry, turn) {
      if (turn && turn.background && trajectory) {
        if (entry.trajectoryState) {
          entry.replayedTexts.push(...entry.trajectoryState.stepFullTexts.values());
          entry.trajectoryState = null;
        }
        if (entry.trajectoryLastSteps != null) {
          entry.trajectoryBaseline = entry.trajectoryLastSteps;
        }
        if (trajectory.cancelInvocation) {
          Promise.resolve(
            trajectory.cancelInvocation(entry.trajectoryPort, entry.sessionId),
          ).catch(() => {});
        }
        turn.finish({ stopReason: 'cancelled' });
        return;
      }
      rpc.notify('session/cancel', { sessionId: entry.sessionId });
    },

    handleMessage(msg) {
      const params = msg.params || {};
      // The agent asks us things too. Permission requests are the only one
      // Relay answers; everything else is refused explicitly so the agent never
      // hangs waiting on a reply that is not coming.
      if (msg.id !== undefined) {
        // Cursor blocks on cursor/ask_question. Relay has no question UI, so
        // skip it instead of letting the permission fallback pick an answer.
        if (skipQuestions && msg.method === 'cursor/ask_question') {
          rpc.reply(msg.id, { outcome: { outcome: 'skipped' } });
          return;
        }
        if (msg.method !== 'session/request_permission') {
          rpc.replyError(msg.id, -32601, `unsupported method: ${msg.method}`);
          return;
        }
        const entry = rpc.sessionFor(params.sessionId);
        const turn = entry && (entry.turn || entry.background);
        const onPermission =
          (turn && turn.onPermission) || (entry && entry.onPermission);
        const title = (params.toolCall && params.toolCall.title) || 'tool call';
        let approve;
        try {
          approve = !!(onPermission && onPermission({ title }));
        } catch (_err) {
          approve = false;
        }
        // The runner decides yes or no; picking the option that says so is
        // protocol knowledge and stays here.
        const options = Array.isArray(params.options) ? params.options : [];
        const pick = (...kinds) => {
          for (const kind of kinds) {
            const found = options.find((option) => option && option.kind === kind);
            if (found) return found.optionId;
          }
          return null;
        };
        // Once, not always: Cursor writes an "always" into the host user's own
        // CLI allowlist, and Relay answers every request anyway.
        const optionId = approve
          ? pick('allow_once', 'allow_always')
          : pick('reject_once', 'reject_always');
        rpc.reply(
          msg.id,
          optionId
            ? { outcome: { outcome: 'selected', optionId } }
            : { outcome: { outcome: 'cancelled' } },
        );
        return;
      }
      if (msg.method !== 'session/update') return;
      const entry = rpc.sessionFor(params.sessionId);
      if (!entry) return;
      const update = params.update || {};
      if (entry.turn) {
        // Antigravity's ACP server tracks stepsSeen only inside session/prompt,
        // so on the next user turn it replays background tool calls and completed
        // planner responses that the trajectory watcher already streamed.
        if (
          update.sessionUpdate === 'tool_call' &&
          update.toolCallId &&
          entry.replayedToolCallIds &&
          entry.replayedToolCallIds.delete(update.toolCallId)
        ) {
          return;
        }
        if (
          update.sessionUpdate === 'agent_message_chunk' &&
          entry.replayedTexts &&
          entry.replayedTexts.length > 0
        ) {
          const text =
            update.content && update.content.type === 'text'
              ? update.content.text
              : '';
          if (text && text === entry.replayedTexts[0]) {
            entry.replayedTexts.shift();
            return;
          }
          entry.replayedTexts.length = 0;
          if (entry.replayedToolCallIds) entry.replayedToolCallIds.clear();
        }
        // Only assistant text reaches the user, and it is what makes a silent
        // retry unsafe.
        if (update.sessionUpdate === 'agent_message_chunk') {
          entry.turn.emitted = true;
        }
        entry.turn.onMessage(update);
        return;
      }
      if (
        entry.onBackgroundTurn &&
        (update.sessionUpdate === 'agent_message_chunk' ||
          update.sessionUpdate === 'tool_call' ||
          update.sessionUpdate === 'usage_update')
      ) {
        const turn =
          entry.background || rpc.startBackgroundTurn(entry, 'acp-background');
        if (!turn) return;
        if (update.sessionUpdate === 'agent_message_chunk') turn.emitted = true;
        turn.onMessage(update);
      }
    },
  };
}

function createAcpSessionPool(options = {}) {
  const {
    authMethod,
    skipQuestions,
    clientMeta,
    modelsMethod,
    trajectory,
    ...poolOptions
  } = options;
  return createStdioAgentPool({
    ...poolOptions,
    driver: (rpc) =>
      createAcpDriver(rpc, {
        authMethod,
        skipQuestions,
        clientMeta,
        modelsMethod,
        trajectory,
      }),
  });
}

module.exports = { createAcpSessionPool };
