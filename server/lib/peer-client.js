'use strict';

// A client for another Relay backend (a "peer") that hosts a Swarm's remote
// members. It speaks only the peer's ordinary HTTP API, so a peer of any
// version works and needs no change. The peer's token comes from the app with
// each request and lives only in this client's closure for that request: it is
// never written to state, history, events, responses, or error messages.

const crypto = require('crypto');

// Short calls (agents, sessions, cancel) and the wait for a turn's stream to
// open. The stream itself has no idle limit, since an agent can work silently
// for minutes; the peer's own turn timeout bounds it.
const REQUEST_TIMEOUT_MS = 15 * 1000;

class PeerError extends Error {
  constructor(message, code) {
    super(message);
    this.code = code;
  }
}

// The peer's canonical address: scheme, lower-cased host, non-default port and
// path without a trailing slash. Returns '' for anything that is not an
// http(s) URL without embedded credentials.
function normalizeBaseUrl(raw) {
  let url;
  try {
    url = new URL(String(raw || '').trim());
  } catch (_err) {
    return '';
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return '';
  if (url.username || url.password) return '';
  return `${url.protocol}//${url.host}${url.pathname.replace(/\/+$/, '')}`;
}

// Derived from the address, not from the app's machine id, because the app
// creates a new random id each time a credential is generated or imported.
function peerIdFor(baseUrl) {
  return crypto.createHash('sha256').update(baseUrl).digest('hex').slice(0, 12);
}

// A remote member key is `<peerId>:<agentKey>`; a local one is the agent key.
function splitMemberKey(memberKey) {
  const match = /^([0-9a-f]{12}):([A-Za-z0-9_-]{1,48})$/.exec(String(memberKey || ''));
  return match ? { peerId: match[1], agentKey: match[2] } : null;
}

function parseEvent(block) {
  let type = 'message';
  const data = [];
  for (const line of block.split('\n')) {
    if (line.startsWith('event:')) type = line.slice(6).trim();
    else if (line.startsWith('data:')) data.push(line.slice(5).trimStart());
  }
  if (!data.length) return null;
  try {
    return { type, payload: JSON.parse(data.join('\n')) };
  } catch (_err) {
    return null;
  }
}

function cancelledError() {
  return new PeerError('request cancelled', 'AGENT_CANCELLED');
}

// Peers known to advertise `features: ['swarm-sessions']` on GET /api/sessions.
// Those peers keep swarm sessions hidden and never activate them, so no active
// session save/restore is needed.
const swarmSessionsPeers = new Set();

// Process-wide ref-counted guard for legacy peers (those without
// `swarm-sessions`). Keyed by `${baseUrl}\0${agent}\0${workdir || ''}` so
// concurrent turns from multiple swarms on the same peer agent capture the
// user's active session once (0->1) and restore it only when all finish (1->0).
const legacyActiveGuards = new Map();
const legacyPendingRestores = new Map();

function createPeerClient({ name, baseUrl, token, deviceId, deviceName }) {
  const label = name || baseUrl;

  function headers(workdir, accept = 'application/json') {
    return {
      Accept: accept,
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
      'x-device-id': deviceId,
      'x-device-name': deviceName,
      ...(workdir ? { 'x-workdir': encodeURI(workdir) } : {}),
    };
  }

  // Sends one request and returns the response once its status is OK. Network
  // failures, timeouts and refusals become PeerErrors that name the machine.
  async function send(path, { method = 'GET', body, workdir, accept, signal } = {}) {
    let res;
    try {
      res = await fetch(`${baseUrl}${path}`, {
        method,
        headers: headers(workdir, accept),
        body: body === undefined ? undefined : JSON.stringify(body),
        signal,
      });
    } catch (err) {
      if (err.name === 'AbortError' || err.name === 'TimeoutError') throw err;
      const reason = (err.cause && err.cause.code) || err.message;
      throw new PeerError(`${label} is unreachable (${reason}).`, 'PEER_UNREACHABLE');
    }
    if (res.ok) return res;
    if (res.status === 401) {
      throw new PeerError(
        `${label} refused this device's credential. Import a current one in Manage Credentials.`,
        'PEER_UNAUTHORIZED',
      );
    }
    let parsed = null;
    try {
      parsed = JSON.parse(await res.text());
    } catch (_err) {
      // Not JSON (a proxy page); the status alone explains it.
    }
    const reason = (parsed && parsed.error) || `HTTP ${res.status}`;
    throw new PeerError(`${label}: ${reason}`, 'PEER_ERROR');
  }

  async function json(path, options = {}) {
    try {
      const res = await send(path, {
        ...options,
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
      return await res.json();
    } catch (err) {
      if (err.name === 'AbortError' || err.name === 'TimeoutError') {
        throw new PeerError(`${label} did not answer in time.`, 'PEER_UNREACHABLE');
      }
      throw err;
    }
  }

  const query = (agent) => `?agent=${encodeURIComponent(agent)}`;

  async function listAgents() {
    const body = await json('/api/agents');
    return Array.isArray(body && body.agents) ? body.agents : [];
  }

  async function fetchSessionsMeta(agent, workdir) {
    const body = await json(`/api/sessions${query(agent)}`, { workdir });
    const features = Array.isArray(body && body.features) ? body.features : [];
    const supportsSwarm = features.includes('swarm-sessions');
    if (supportsSwarm) swarmSessionsPeers.add(baseUrl);
    return {
      supportsSwarm,
      activeSessionId: (body && body.activeSessionId) || '',
    };
  }

  // Runs `task(supportsSwarm)` while guarding the peer user's active session
  // for legacy peers. New peers advertising `swarm-sessions` skip save/restore
  // completely; legacy peers ref-count concurrent calls per (peer, agent,
  // workdir), capturing on 0->1 and restoring on 1->0.
  async function withActiveSessionGuard(agent, workdir, task) {
    if (swarmSessionsPeers.has(baseUrl)) {
      return task(true);
    }
    const key = `${baseUrl}\0${agent}\0${workdir || ''}`;
    let entry = legacyActiveGuards.get(key);
    if (!entry) {
      entry = {
        count: 0,
        previous: '',
        supportsSwarm: false,
        capturePromise: null,
      };
      legacyActiveGuards.set(key, entry);
    }
    entry.count += 1;
    if (entry.count === 1) {
      const pendingRestore = legacyPendingRestores.get(key);
      entry.capturePromise = (async () => {
        if (pendingRestore) await pendingRestore;
        const meta = await fetchSessionsMeta(agent, workdir);
        entry.supportsSwarm = meta.supportsSwarm;
        entry.previous = meta.supportsSwarm ? '' : meta.activeSessionId;
        return meta;
      })();
    }
    try {
      await entry.capturePromise;
      return await task(entry.supportsSwarm);
    } finally {
      entry.count -= 1;
      if (entry.count === 0) {
        if (legacyActiveGuards.get(key) === entry) legacyActiveGuards.delete(key);
        if (!entry.supportsSwarm && entry.previous) {
          const restore = restoreActive(agent, workdir, entry.previous).finally(() => {
            if (legacyPendingRestores.get(key) === restore) {
              legacyPendingRestores.delete(key);
            }
          });
          legacyPendingRestores.set(key, restore);
          await restore;
        }
      }
    }
  }

  // Creates a hidden swarm session on the peer (`kind: 'swarm'`). New peers
  // keep it hidden and never activate it; legacy peers ignore `kind` and
  // activate it, so the guard restores the user's previous active session.
  async function createSession(agent, workdir, sessionName) {
    return withActiveSessionGuard(agent, workdir, async () => {
      const body = await json('/api/sessions', {
        method: 'POST',
        workdir,
        body: { agent, name: sessionName, kind: 'swarm' },
      });
      return {
        sessionId: body.sessionId || body.activeSessionId,
        workdir: body.workdir || workdir,
      };
    });
  }

  function restoreActive(agent, workdir, sessionId) {
    return json('/api/sessions/active', {
      method: 'POST',
      workdir,
      body: { agent, sessionId },
    }).catch(() => {});
  }

  function deleteSession(agent, workdir, sessionId) {
    return json('/api/sessions/delete', {
      method: 'POST',
      workdir,
      body: { agent, sessionId },
    });
  }

  function clearSession(agent, workdir, sessionId) {
    return json('/api/session/clear', {
      method: 'POST',
      workdir,
      body: { agent, sessionId },
    });
  }

  function cancel(requestId, workdir) {
    return json('/api/chat/cancel', {
      method: 'POST',
      workdir,
      body: { requestId },
    }).catch(() => {});
  }

  // One turn on the peer, in the runAgent contract: streamed progress, deltas
  // and segment boundaries go to onEvent, the reply text is returned, a failed
  // turn throws, and a cancelled one throws AGENT_CANCELLED. Aborting `signal`
  // forwards the cancel to the peer. On legacy peers a turn also makes its
  // session active, so the guard restores the user's active session once all
  // concurrent turns on that agent finish.
  async function chat({ agent, sessionId, workdir, prompt, requestId, signal, onEvent }) {
    if (signal && signal.aborted) throw cancelledError();
    return withActiveSessionGuard(agent, workdir, async () => {
      if (signal && signal.aborted) throw cancelledError();
      const controller = new AbortController();
      const onAbort = () => {
        cancel(requestId, workdir);
        controller.abort();
      };
      if (signal) signal.addEventListener('abort', onAbort, { once: true });
      const openTimer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
      try {
        let res;
        try {
          res = await send('/api/chat', {
            method: 'POST',
            workdir,
            accept: 'text/event-stream',
            body: { agent, sessionId, prompt, requestId },
            signal: controller.signal,
          });
        } finally {
          clearTimeout(openTimer);
        }
        if (!String(res.headers.get('content-type') || '').includes('text/event-stream')) {
          const reply = await res.json();
          return String((reply && reply.message && reply.message.content) || '');
        }
        const decoder = new TextDecoder();
        let buffer = '';
        for await (const chunk of res.body) {
          buffer += decoder.decode(chunk, { stream: true }).replace(/\r\n/g, '\n');
          let index;
          while ((index = buffer.indexOf('\n\n')) >= 0) {
            const event = parseEvent(buffer.slice(0, index));
            buffer = buffer.slice(index + 2);
            if (!event) continue;
            const payload = event.payload || {};
            if (event.type === 'agent_delta') {
              onEvent({ type: 'delta', text: String(payload.text || '') });
            } else if (event.type === 'agent_progress') {
              onEvent({ type: 'progress', line: String(payload.line || '') });
            } else if (event.type === 'agent_segment') {
              onEvent({ type: 'segment' });
            } else if (event.type === 'agent_done') {
              return String((payload.message && payload.message.content) || '');
            } else if (event.type === 'agent_error') {
              throw new PeerError(
                `${label}: ${payload.error || 'agent request failed'}`,
                payload.code || 'AGENT_ERROR',
              );
            } else if (event.type === 'agent_cancelled') {
              throw cancelledError();
            }
          }
        }
        throw new PeerError(`${label} closed the reply before it finished.`, 'PEER_UNREACHABLE');
      } catch (err) {
        if (signal && signal.aborted) throw cancelledError();
        if (err.name === 'AbortError' || err.name === 'TimeoutError') {
          throw new PeerError(`${label} did not answer in time.`, 'PEER_UNREACHABLE');
        }
        throw err;
      } finally {
        if (signal) signal.removeEventListener('abort', onAbort);
        controller.abort();
      }
    });
  }

  return { listAgents, createSession, deleteSession, clearSession, chat };
}

module.exports = {
  PeerError,
  createPeerClient,
  normalizeBaseUrl,
  peerIdFor,
  splitMemberKey,
};
