'use strict';

const { randomUUID } = require('crypto');
const os = require('os');
const express = require('express');
const { wantsStream, writeStreamEvent, endStream } = require('../lib/sse');

const {
  handleSlug,
  parseMentions,
  deltaSince,
  lastSpeaker,
  buildGroupPrompt,
} = require('../lib/group-turn');
const { normalizeSettings } = require('../lib/agent-options');
const {
  PeerError,
  normalizeBaseUrl,
  peerIdFor,
  splitMemberKey,
} = require('../lib/peer-client');

// Multi-agent group chat: one human, several agents, one canonical transcript.
// The orchestrator reuses the single-agent turn pipeline (runAgentTurn) once for
// every summoned member. Members in one wave run one after another in mention
// order, each planned right before it runs so its unseen transcript delta
// includes replies already given earlier in the same wave, against its OWN
// resumable CLI session (see docs/handbook.md, "Swarms"). The canonical
// transcript uses a dedicated scope agent key so it never mixes with solo
// conversations. A remote member (`<peerId>:<agentKey>`) runs on another Relay
// backend: its turn goes through the same runAgentTurn with runAgent replaced by
// a call to that peer's /api/chat, using the credential the app sent with this
// request.
const GROUP_SCOPE_PREFIX = 'group:';
const HUMAN_AUTHOR = 'human';

// A member's reply can summon other members, so one human message can run
// several waves of turns. Cap how many of those agent-driven waves follow the
// human's, since two members that keep naming each other would otherwise talk
// (and bill) forever. 0 restores human-only summoning.
const DEFAULT_MAX_MENTION_HOPS = 3;

function maxMentionHops(env = process.env) {
  const raw = Number.parseInt(env.RELAY_SWARM_MAX_HOPS ?? '', 10);
  if (!Number.isFinite(raw) || raw < 0) return DEFAULT_MAX_MENTION_HOPS;
  return Math.min(raw, 20);
}

// A responder shared across every agent turn in one round. Unlike the single-chat
// responder it does NOT end the stream after each agent (final()), so the route
// can close it once the whole round drains. Non-streaming requests get one JSON
// reply from the route after the loop instead. event() reports every event as
// unhandled, so a turn also broadcasts it and devices that did not start the
// round still see members' progress.
function createRoundResponder(res, streaming) {
  let opened = false;
  return {
    streaming,
    ready(requestId) {
      if (!streaming || opened) return;
      opened = true;
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache, no-transform',
        Connection: 'keep-alive',
      });
      writeStreamEvent(res, 'ready', { ok: true, requestId });
    },
    event(type, payload) {
      if (streaming) writeStreamEvent(res, type, payload);
      return false;
    },
    async fallbackText() {},
    final(reply) {
      if (streaming) writeStreamEvent(res, 'agent_done', reply);
    },
    cancelled(payload) {
      if (streaming) writeStreamEvent(res, 'agent_cancelled', payload);
    },
    authError(payload) {
      if (streaming) writeStreamEvent(res, 'agent_error', payload);
    },
    error(payload) {
      if (streaming) writeStreamEvent(res, 'agent_error', payload);
    },
  };
}

module.exports = function createGroupRouter(ctx) {
  const {
    MAX_PROMPT_BYTES,
    activeRequests,
    agentPayload = (agent) => ({ key: agent.key, label: agent.label }),
    agentTurnDependencies,
    clearHistory,
    createGroup,
    createPeerClient,
    deleteGroup,
    findGroup,
    getDefaultWorkdir,
    purgeSession,
    finalizeStaleStreamingHistory,
    getAgent,
    listAllGroups,
    localMachineName,
    nextGroupName,
    normalizeDeviceId,
    notifyTaskCompletion,
    readHistory,
    requestWorkdir,
    runAgentTurn,
    runningScopes,
    scopeChains,
    scopeKeyFor,
    sendEvent,
    sendWorkdirError,
    sessionContextKeyFor,
    setGroupMembers,
    setGroupWorkdir,
    touchGroup,
    upsertHistoryMessage,
    validateWorkdir,
  } = ctx;
  const router = express.Router();
  const maxHops = maxMentionHops();
  const hostName =
    (typeof localMachineName === 'string' && localMachineName.trim()) ||
    (os.hostname() || '').split('.')[0].trim() ||
    'local';

  const groupScopeKeyFor = (workdir, groupId) =>
    sessionContextKeyFor(`${GROUP_SCOPE_PREFIX}${groupId}`, workdir);
  // A member's private resumable CLI session for this swarm (keeps its own memory,
  // separate from the member's solo Main chat in the same work tree).
  const memberSessionKeyFor = (workdir, groupId, memberKey) =>
    scopeKeyFor(memberKey, workdir, groupId);
  // The round running in this swarm, so a device that reopens it can show Stop
  // and cancel it. One round runs at a time, so the first match is the round.
  const runningRoundFor = (scopeKey) => {
    for (const runState of activeRequests.values()) {
      if (runState.group && runState.scopeKey === scopeKey) return runState.requestId;
    }
    return null;
  };
  const baseLabelFor = (memberKey) => {
    const remote = splitMemberKey(memberKey);
    const agent = getAgent(remote ? remote.agentKey : memberKey);
    return agent ? agent.label : remote ? remote.agentKey : memberKey;
  };
  // A member's default label: a remote member always names its machine, and a
  // local member names this machine only when another member in the swarm shares
  // the same agent label (e.g. two "Claude Code").
  const defaultLabelFor = (group, memberKey) => {
    const remote = splitMemberKey(memberKey);
    const base = baseLabelFor(memberKey);
    if (remote) {
      const peer = group.peers && group.peers[remote.peerId];
      return `${base} (${peer ? peer.name : remote.peerId})`;
    }
    const members = Array.isArray(group.members) ? group.members : [];
    const duplicates = members.filter((key) => baseLabelFor(key) === base).length;
    return duplicates > 1 ? `${base} (${hostName})` : base;
  };
  // Readable mention handle: `@<agent>` for local members, `@<peer-slug>:<agent>`
  // for remote members (falling back to `@<peerId>:<agent>` if the peer name
  // has no ASCII slug or collides with another peer in the swarm).
  const handleFor = (group, memberKey) => {
    const remote = splitMemberKey(memberKey);
    if (!remote) return memberKey;
    const peers = (group && group.peers) || {};
    const peer = peers[remote.peerId];
    const slug = peer ? handleSlug(peer.name) : '';
    if (!slug) return memberKey;
    const collision = Object.entries(peers).some(
      ([id, info]) => id !== remote.peerId && handleSlug(info && info.name) === slug,
    );
    return collision ? memberKey : `${slug}:${remote.agentKey}`;
  };
  // The agent a member's turn is attributed to. A remote member is described by
  // its member key and label only; its peer owns everything else about it.
  const memberAgentFor = (group, memberKey) => {
    const remote = splitMemberKey(memberKey);
    if (!remote) {
      const agent = getAgent(memberKey);
      if (!agent) return null;
      return { ...agent, label: defaultLabelFor(group, memberKey) };
    }
    if (!group.peers[remote.peerId]) return null;
    return { key: memberKey, label: defaultLabelFor(group, memberKey) };
  };

  // The peer credentials the app sent with this request, keyed by peer id.
  // They exist only for the life of the request.
  function requestPeers(req) {
    const out = new Map();
    const list = Array.isArray(req.body && req.body.peers) ? req.body.peers : [];
    for (const raw of list) {
      if (!raw || typeof raw !== 'object') continue;
      const baseUrl = normalizeBaseUrl(raw.baseUrl);
      const token = typeof raw.token === 'string' ? raw.token.trim() : '';
      if (!baseUrl || !token || token.length > 4096) continue;
      const name = typeof raw.name === 'string' ? raw.name.replace(/\s+/g, ' ').trim() : '';
      out.set(peerIdFor(baseUrl), {
        name: name.slice(0, 80) || new URL(baseUrl).host,
        baseUrl,
        token,
      });
    }
    return out;
  }

  // A client for one peer, or null when this request carries no credential for
  // it. It identifies itself to the peer with the app's own device headers.
  function peerClientFor(req, credentials, peerId, record) {
    const credential = credentials.get(peerId);
    if (!credential) return null;
    return createPeerClient({
      name: (record && record.name) || credential.name,
      baseUrl: credential.baseUrl,
      token: credential.token,
      deviceId: normalizeDeviceId(req.get('x-device-id')) || 'relay-swarm',
      deviceName: String(req.get('x-device-name') || 'Relay Swarm').slice(0, 120),
    });
  }

  function notLinkedError(peerName) {
    return new PeerError(
      `${peerName} is not connected on this device. Add its credential in Manage Credentials.`,
      'PEER_NOT_LINKED',
    );
  }

  function sendPeerError(res, err) {
    if (!(err instanceof PeerError)) {
      return res.status(500).json({ error: err.message || 'request failed' });
    }
    const status = ['PEER_NOT_LINKED', 'PEER_UNKNOWN_AGENT'].includes(err.code) ? 400 : 502;
    return res.status(status).json({ error: err.message, code: err.code });
  }

  // Checks each new remote member against its peer (reachable, agent exists)
  // and creates its dedicated session there, in the work tree the caller chose
  // on that machine (the peer's default when none). Returns the configs and
  // peer records to store, plus a rollback that deletes those sessions again;
  // a failure rolls back itself, so no peer keeps a half-made member.
  async function linkRemoteMembers(req, credentials, memberKeys, rawConfigs, swarmName) {
    const configs = {};
    const peers = {};
    const created = [];
    const rollback = () => Promise.all(created.map(({ client, agentKey, workdir, sessionId }) =>
      client.deleteSession(agentKey, workdir, sessionId).catch(() => {})));
    const agentsByPeer = new Map();
    try {
      for (const memberKey of memberKeys) {
        const { peerId, agentKey } = splitMemberKey(memberKey);
        const credential = credentials.get(peerId);
        if (!credential) throw notLinkedError(peerId);
        const client = peerClientFor(req, credentials, peerId);
        if (!agentsByPeer.has(peerId)) agentsByPeer.set(peerId, await client.listAgents());
        if (!agentsByPeer.get(peerId).some((agent) => agent && agent.key === agentKey)) {
          throw new PeerError(
            `${credential.name} has no agent "${agentKey}".`,
            'PEER_UNKNOWN_AGENT',
          );
        }
        const raw = rawConfigs && rawConfigs[memberKey];
        const workdir = raw && typeof raw.workdir === 'string' ? raw.workdir.trim() : '';
        const session = await client.createSession(agentKey, workdir, `Swarm: ${swarmName}`);
        created.push({ client, agentKey, ...session });
        // A re-added member's new session has none of its earlier replies.
        configs[memberKey] = {
          workdir: session.workdir,
          sessionId: session.sessionId,
          resetAt: new Date().toISOString(),
        };
        peers[peerId] = { name: credential.name, baseUrl: credential.baseUrl };
      }
    } catch (err) {
      await rollback();
      throw err;
    }
    return { configs, peers, rollback };
  }

  // Best-effort `delete` or `clear` of remote members' sessions on their peers.
  // A member whose peer has no credential in this request, or whose peer fails,
  // is skipped, so the local change never depends on another machine.
  function forgetRemoteMembers(req, credentials, group, memberKeys, action) {
    return Promise.all(memberKeys.map((memberKey) => {
      const remote = splitMemberKey(memberKey);
      const config = group.memberConfigs[memberKey] || {};
      const client = remote && peerClientFor(req, credentials, remote.peerId);
      if (!client || !config.sessionId) return null;
      const call = action === 'clear' ? client.clearSession : client.deleteSession;
      return call(remote.agentKey, config.workdir, config.sessionId).catch(() => {});
    }));
  }

  // The work tree a swarm runs in: its pinned `workdir`, falling back to the
  // workspace it was created in for swarms saved before work-tree selection.
  const runWorkdirOf = (group, workspace) => group.workdir || workspace;

  function resolveWorkdir(req, res) {
    try {
      return requestWorkdir(req);
    } catch (err) {
      sendWorkdirError(res, err);
      return null;
    }
  }

  // The work tree chosen for a new swarm or workdir update: an explicit,
  // existing directory (or the machine's default dir, created if missing) or
  // the workspace when none is given. Returns null (after sending an error)
  // when the path is set but invalid, so the caller bails out.
  function resolveWorkTree(res, rawPath, workspace) {
    const raw = String(rawPath || '').trim();
    if (!raw) return workspace;
    const defaultDir = typeof getDefaultWorkdir === 'function' ? getDefaultWorkdir() : '';
    try {
      return validateWorkdir(raw, { create: Boolean(defaultDir && raw === defaultDir) }).dir;
    } catch (err) {
      sendWorkdirError(res, err);
      return null;
    }
  }

  // Per-member config: model/effort/permission/fast normalized for that
  // agent (unknown ids fall back to defaults), plus the free-text swarm-scoped
  // `nickname` and `prompt` passed through (groups.js bounds their length). Only
  // current members are kept, so a config can never reference a dropped member.
  // A remote member runs with its peer's own settings, so it keeps only the
  // persona. The peer `workdir`/`sessionId` and every member's `resetAt` are
  // the server's own and come from `linked`, never from the caller.
  function normalizeConfigs(rawConfigs, members, linked = {}) {
    const out = {};
    const configs = rawConfigs && typeof rawConfigs === 'object' ? rawConfigs : {};
    for (const memberKey of members) {
      const raw = configs[memberKey] && typeof configs[memberKey] === 'object'
        ? configs[memberKey]
        : null;
      const { workdir, sessionId, resetAt } = linked[memberKey] || {};
      let config = {};
      if (splitMemberKey(memberKey)) config = { workdir, sessionId };
      else if (raw) config = normalizeSettings(memberKey, raw);
      if (raw && typeof raw.nickname === 'string') config.nickname = raw.nickname;
      if (raw && typeof raw.prompt === 'string') config.prompt = raw.prompt;
      if (resetAt) config.resetAt = resetAt;
      out[memberKey] = config;
    }
    return out;
  }

  // Members the caller asked for, narrowed to agents that actually exist on this
  // host. Unknown agent keys are dropped so a group can never reference a runner
  // that isn't installed. Remote members are checked against their peer when
  // they are added (linkRemoteMembers).
  function knownMembers(rawMembers) {
    const list = Array.isArray(rawMembers) ? rawMembers : [];
    return list
      .map((m) => String(m || '').trim())
      .filter((m) => m && (splitMemberKey(m) || getAgent(m)));
  }

  router.get('/api/groups', (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    return res.json({ workdir, groups: listAllGroups() });
  });

  router.post('/api/groups', async (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const members = knownMembers(req.body.members);
    if (members.length === 0) {
      return res
        .status(400)
        .json({ error: 'at least one known agent member is required', code: 'GROUP_NO_MEMBERS' });
    }
    const workTree = resolveWorkTree(res, req.body.workdir, workdir);
    if (workTree === null) return undefined;
    // Named before creation because each remote member's session carries it.
    const name = String(req.body.name || '').replace(/\s+/g, ' ').trim().slice(0, 80) ||
      nextGroupName(listAllGroups());
    let linked;
    try {
      linked = await linkRemoteMembers(
        req, requestPeers(req), members.filter(splitMemberKey), req.body.configs, name,
      );
    } catch (err) {
      return sendPeerError(res, err);
    }
    const group = createGroup(workdir, name, members, {
      workdir: workTree,
      memberConfigs: normalizeConfigs(req.body.configs, members, linked.configs),
      peers: linked.peers,
    });
    if (!group) {
      await linked.rollback();
      return res
        .status(409)
        .json({ error: 'too many swarms in this workspace', code: 'GROUP_LIMIT' });
    }
    return res.json({ ok: true, workdir, group, groups: listAllGroups() });
  });

  router.post('/api/groups/members', async (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const groupId = String(req.body.groupId || '').trim();
    const members = knownMembers(req.body.members);
    if (members.length === 0) {
      return res
        .status(400)
        .json({ error: 'at least one known agent member is required', code: 'GROUP_NO_MEMBERS' });
    }
    const found = findGroup(groupId);
    if (!found) {
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    const { workspace, group: existing } = found;
    const credentials = requestPeers(req);
    let linked;
    try {
      linked = await linkRemoteMembers(
        req,
        credentials,
        members.filter((key) => splitMemberKey(key) && !existing.members.includes(key)),
        req.body.configs,
        existing.name,
      );
    } catch (err) {
      return sendPeerError(res, err);
    }
    // A member the caller sends no config for keeps its stored one, so a
    // client that only changes members (relay-mcp) resets nobody's settings.
    const rawConfigs = req.body.configs && typeof req.body.configs === 'object'
      ? req.body.configs
      : {};
    const group = setGroupMembers(workspace, groupId, members, {
      memberConfigs: normalizeConfigs(
        { ...existing.memberConfigs, ...rawConfigs },
        members,
        { ...existing.memberConfigs, ...linked.configs },
      ),
      peers: linked.peers,
    });
    if (!group) {
      await linked.rollback();
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    await forgetRemoteMembers(
      req,
      credentials,
      existing,
      existing.members.filter((key) => !members.includes(key)),
      'delete',
    );
    return res.json({ ok: true, workdir, group, groups: listAllGroups() });
  });

  // Change a swarm's local work tree and/or remote members' peer workdirs.
  // Validates every changed directory first (local via validateWorkdir, remote
  // via peer session creation with rollback on failure) and resets only the
  // affected members' sessions. Refused while a round is running.
  router.post('/api/groups/workdir', async (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const groupId = String(req.body.groupId || '').trim();
    const found = findGroup(groupId);
    if (!found) {
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    const { workspace, group: existing } = found;
    const oldRunWorkdir = runWorkdirOf(existing, workspace);
    const oldScopeKey = groupScopeKeyFor(oldRunWorkdir, existing.id);
    if (runningScopes.has(oldScopeKey) || scopeChains.has(oldScopeKey)) {
      return res.status(409).json({ error: 'group has a running turn', code: 'GROUP_BUSY' });
    }
    let nextLocalWorkdir = oldRunWorkdir;
    let localChanged = false;
    const rawLocal = typeof req.body.workdir === 'string' ? req.body.workdir.trim() : '';
    if (rawLocal) {
      const validated = resolveWorkTree(res, rawLocal, oldRunWorkdir);
      if (validated === null) return undefined;
      if (validated !== oldRunWorkdir) {
        nextLocalWorkdir = validated;
        localChanged = true;
      }
    }
    const rawMemberWorkdirs =
      req.body.memberWorkdirs && typeof req.body.memberWorkdirs === 'object'
        ? req.body.memberWorkdirs
        : {};
    const changedRemote = [];
    for (const [memberKey, rawDir] of Object.entries(rawMemberWorkdirs)) {
      if (!splitMemberKey(memberKey) || !existing.members.includes(memberKey)) continue;
      const dir = typeof rawDir === 'string' ? rawDir.trim() : '';
      const prevDir = (existing.memberConfigs[memberKey] && existing.memberConfigs[memberKey].workdir) || '';
      if (dir && dir !== prevDir) {
        changedRemote.push({ memberKey, workdir: dir });
      }
    }
    if (!localChanged && changedRemote.length === 0) {
      return res.json({ ok: true, workdir, group: existing, groups: listAllGroups() });
    }
    const credentials = requestPeers(req);
    const remoteUpdates = {};
    const created = [];
    const rollback = () => Promise.all(created.map(({ client, agentKey, workdir: dir, sessionId }) =>
      client.deleteSession(agentKey, dir, sessionId).catch(() => {})));
    try {
      for (const { memberKey, workdir: newDir } of changedRemote) {
        const { peerId, agentKey } = splitMemberKey(memberKey);
        const peer = existing.peers[peerId];
        const client = peerClientFor(req, credentials, peerId, peer);
        if (!client) throw notLinkedError((peer && peer.name) || peerId);
        const session = await client.createSession(agentKey, newDir, `Swarm: ${existing.name}`);
        created.push({ client, agentKey, ...session });
        remoteUpdates[memberKey] = { workdir: session.workdir, sessionId: session.sessionId };
      }
    } catch (err) {
      await rollback();
      return sendPeerError(res, err);
    }
    const updated = setGroupWorkdir(workspace, existing.id, {
      workdir: localChanged ? nextLocalWorkdir : undefined,
      remoteUpdates,
    });
    if (!updated) {
      await rollback();
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    if (localChanged) {
      const newScopeKey = groupScopeKeyFor(nextLocalWorkdir, existing.id);
      if (newScopeKey !== oldScopeKey) {
        const messages = readHistory(oldScopeKey);
        for (const message of messages) upsertHistoryMessage(newScopeKey, message);
        clearHistory(oldScopeKey);
      }
      for (const memberKey of existing.members.filter((key) => !splitMemberKey(key))) {
        await purgeSession(memberSessionKeyFor(oldRunWorkdir, existing.id, memberKey), {
          agentKey: memberKey,
          workdir: oldRunWorkdir,
        });
      }
    }
    await forgetRemoteMembers(
      req,
      credentials,
      existing,
      changedRemote.map((item) => item.memberKey),
      'delete',
    );
    return res.json({ ok: true, workdir, group: updated, groups: listAllGroups() });
  });

  router.post('/api/groups/delete', async (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const groupId = String(req.body.groupId || '').trim();
    const found = findGroup(groupId);
    if (!found) {
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    const { workspace, group } = found;
    const runWorkdir = runWorkdirOf(group, workspace);
    const scopeKey = groupScopeKeyFor(runWorkdir, group.id);
    if (runningScopes.has(scopeKey) || scopeChains.has(scopeKey)) {
      return res.status(409).json({ error: 'group has a running turn', code: 'GROUP_BUSY' });
    }
    deleteGroup(workspace, group.id);
    clearHistory(scopeKey);
    await forgetRemoteMembers(req, requestPeers(req), group, group.members, 'delete');
    for (const memberKey of group.members.filter((key) => !splitMemberKey(key))) {
      await purgeSession(memberSessionKeyFor(runWorkdir, group.id, memberKey), {
        agentKey: memberKey,
        workdir: runWorkdir,
      });
    }
    return res.json({ ok: true, workdir, groups: listAllGroups() });
  });

  router.get('/api/group/history', (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const groupId = String(req.query.groupId || '').trim();
    const found = findGroup(groupId);
    if (!found) {
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    const { workspace, group } = found;
    const scopeKey = groupScopeKeyFor(runWorkdirOf(group, workspace), group.id);
    if (!runningScopes.has(scopeKey) && !scopeChains.has(scopeKey)) {
      finalizeStaleStreamingHistory(scopeKey);
    }
    return res.json({
      workdir,
      group,
      messages: readHistory(scopeKey),
      runningRequestId: runningRoundFor(scopeKey),
    });
  });

  // Reset a swarm's transcript and every member's forked CLI session, keeping the
  // swarm itself. The next message starts the conversation afresh.
  router.post('/api/group/clear', async (req, res) => {
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const groupId = String(req.body.groupId || '').trim();
    const found = findGroup(groupId);
    if (!found) {
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    const { workspace, group } = found;
    const runWorkdir = runWorkdirOf(group, workspace);
    const scopeKey = groupScopeKeyFor(runWorkdir, group.id);
    if (runningScopes.has(scopeKey) || scopeChains.has(scopeKey)) {
      return res.status(409).json({ error: 'group has a running turn', code: 'GROUP_BUSY' });
    }
    clearHistory(scopeKey);
    await forgetRemoteMembers(req, requestPeers(req), group, group.members, 'clear');
    for (const memberKey of group.members.filter((key) => !splitMemberKey(key))) {
      await purgeSession(memberSessionKeyFor(runWorkdir, group.id, memberKey), {
        agentKey: memberKey,
        workdir: runWorkdir,
      });
    }
    return res.json({ ok: true, workdir, group });
  });

  router.post('/api/group/chat/cancel', (req, res) => {
    const requestId = String(req.body.requestId || '').trim();
    if (!requestId) {
      return res.status(400).json({ error: 'requestId is required' });
    }
    const runState = activeRequests.get(requestId);
    if (!runState || !runState.group) {
      return res.status(404).json({ error: 'request not found', code: 'REQUEST_NOT_FOUND' });
    }
    runState.cancelled = true;
    if (!runState.cancelEventSent) {
      runState.cancelEventSent = true;
      sendEvent('group_cancelled', {
        groupId: runState.group.id,
        requestId,
        deviceId: runState.deviceId,
        createdAt: new Date().toISOString(),
      });
    }
    runState.abortController.abort();
    return res.json({ ok: true, requestId });
  });

  router.post('/api/group/chat', async (req, res) => {
    const groupId = String(req.body.groupId || '').trim();
    const requestId = String(req.body.requestId || randomUUID()).trim();
    const prompt = String(req.body.prompt || '').trim();
    const deviceId = normalizeDeviceId(req.get('x-device-id'));
    if (!prompt) {
      return res.status(400).json({ error: 'prompt is required' });
    }
    if (Buffer.byteLength(prompt, 'utf8') > MAX_PROMPT_BYTES) {
      return res
        .status(413)
        .json({ error: 'prompt exceeds the size limit', code: 'PROMPT_TOO_LARGE' });
    }
    if (activeRequests.has(requestId)) {
      return res.status(409).json({ error: 'request already running', code: 'REQUEST_BUSY' });
    }
    const workdir = resolveWorkdir(req, res);
    if (workdir === null) return undefined;
    const found = findGroup(groupId);
    if (!found) {
      return res.status(404).json({ error: 'group not found', code: 'GROUP_NOT_FOUND' });
    }
    const { workspace, group } = found;

    // History, member sessions and the agents themselves all run in the swarm's
    // own work tree (falling back to the bucket workspace for legacy swarms).
    const runWorkdir = runWorkdirOf(group, workspace);
    const scopeKey = groupScopeKeyFor(runWorkdir, group.id);
    // One round at a time: a second one would interleave its waves with the
    // first in the shared transcript and feed members each other's half-done
    // turns. Stop the running round to start another.
    if (runningScopes.has(scopeKey)) {
      return res
        .status(409)
        .json({ error: 'swarm has a running round', code: 'GROUP_BUSY' });
    }
    // A member's display name inside this swarm: its user-set nickname when
    // present, otherwise the agent's default label (with machine name when two
    // members share an agent label). Used for @mention matching, speaker labels
    // in each prompt, and the recorded message attribution.
    const groupLabelFor = (agentKey) => {
      const nickname = group.memberConfigs[agentKey] &&
        group.memberConfigs[agentKey].nickname;
      return (typeof nickname === 'string' && nickname) || defaultLabelFor(group, agentKey);
    };
    const groupHandleFor = (memberKey) => handleFor(group, memberKey);
    const locationFor = (memberKey) => {
      const remote = splitMemberKey(memberKey);
      if (!remote) return { machine: hostName, workdir: runWorkdir };
      const peer = group.peers[remote.peerId];
      const config = group.memberConfigs[memberKey] || {};
      return {
        machine: (peer && peer.name) || remote.peerId,
        workdir: config.workdir || '',
      };
    };
    const credentials = requestPeers(req);
    let mentions = parseMentions(prompt, group.members, groupLabelFor, groupHandleFor);
    if (mentions.length === 0) {
      // A message that names no one is a follow-up ("continue") to whoever
      // spoke last; before anyone has, it would summon no one, so refuse it.
      const last = lastSpeaker(readHistory(scopeKey), group.members);
      if (!last) {
        return res.status(400).json({
          error: 'mention a member with @ to start the conversation',
          code: 'GROUP_NO_MENTION',
        });
      }
      mentions = [last];
    }
    const abortController = new AbortController();
    const runState = {
      requestId,
      group: { id: group.id, name: group.name },
      session: { id: group.id, name: group.name },
      deviceId,
      scopeKey,
      scopeWorkdir: workspace,
      cancelled: false,
      cancelEventSent: false,
      abortController,
    };
    activeRequests.set(requestId, runState);
    const responder = createRoundResponder(res, wantsStream(req));
    responder.ready(requestId);

    // Record the human message once per round (not once per summoned agent), then
    // broadcast to every connected device so anyone viewing this swarm sees it
    // regardless of their current solo-chat workdir.
    const createdAt = new Date().toISOString();
    const humanMessageId = `${requestId}:human`;
    upsertHistoryMessage(scopeKey, {
      id: humanMessageId,
      role: 'user',
      content: prompt,
      agent: HUMAN_AUTHOR,
      createdAt,
      metadata: {
        author: HUMAN_AUTHOR,
        summonedBy: HUMAN_AUTHOR,
        groupId: group.id,
        groupName: group.name,
        mentions,
      },
    });
    sendEvent('group_message', {
      groupId: group.id,
      requestId,
      deviceId,
      mentions,
      message: {
        id: humanMessageId,
        role: 'user',
        author: HUMAN_AUTHOR,
        content: prompt,
        createdAt,
      },
      createdAt,
    });

    const base = agentTurnDependencies();
    // Mark the group scope busy for the whole round. This group scope key is what
    // the delete/clear/workdir/history routes consult to tell the round is running.
    runningScopes.add(scopeKey);

    // Everyone this member is allowed to hand the floor to, with its readable
    // handle, machine and work tree. Empty when agent-to-agent summoning is off.
    const rosterFor = (memberKey) =>
      maxHops === 0
        ? []
        : group.members
            .filter((key) => key !== memberKey)
            .map((key) => ({
              key,
              handle: groupHandleFor(key),
              label: groupLabelFor(key),
              ...locationFor(key),
            }));

    // Plan one member's prompt right before it runs, snapshotting the transcript
    // fresh so its delta includes replies already given earlier in this wave.
    const planMember = ({ memberKey, summonedBy }, wave, index) => {
      const memberAgent = memberAgentFor(group, memberKey);
      if (!memberAgent) return null;
      const snapshot = readHistory(scopeKey);
      const memberSessionKey = memberSessionKeyFor(runWorkdir, group.id, memberKey);
      const memberConfig = group.memberConfigs[memberKey] || {};
      // Plan B: feed this member only what happened since it last spoke, each
      // line labeled with its speaker. Its own resumable session has the rest.
      const delta = deltaSince(snapshot, memberKey, memberConfig.resetAt);
      const selfLoc = locationFor(memberKey);
      const groupPrompt = buildGroupPrompt({
        selfLabel: groupLabelFor(memberKey),
        selfMachine: selfLoc.machine,
        selfWorkdir: selfLoc.workdir,
        persona: memberConfig.prompt,
        delta,
        labelFor: groupLabelFor,
        roster: rosterFor(memberKey),
        maxBytes: Math.max(1024, MAX_PROMPT_BYTES - 1024),
      });
      return {
        memberKey,
        memberAgent,
        memberSessionKey,
        groupPrompt,
        summonedBy,
        turnRequestId: `${requestId}.${wave}.${index}.${memberKey}`,
      };
    };

    // Who the replies of a finished wave handed the floor to. A member never
    // summons itself (that would never terminate), is skipped when it already
    // ran after the mentioning reply in this same wave (it already saw that
    // reply), and is summoned once per wave however many siblings named it.
    // Failed and cancelled turns are skipped: their recorded content is an error
    // message, not something an agent chose to say.
    const nextSummons = (results) => {
      const seen = new Set();
      const out = [];
      for (let i = 0; i < results.length; i += 1) {
        const result = results[i];
        if (!result || result.status !== 'done') continue;
        const ranAfter = new Set(
          results.slice(i + 1).map((r) => r && r.agent).filter(Boolean),
        );
        const summoned = parseMentions(
          result.content,
          group.members,
          groupLabelFor,
          groupHandleFor,
        );
        for (const memberKey of summoned) {
          if (memberKey === result.agent || seen.has(memberKey) || ranAfter.has(memberKey)) {
            continue;
          }
          seen.add(memberKey);
          out.push({ memberKey, summonedBy: result.agent });
        }
      }
      return out;
    };

    // One summoned member's turn.
    const runMember = async ({
      memberKey,
      memberAgent,
      memberSessionKey,
      groupPrompt,
      summonedBy,
      turnRequestId,
    }) => {
      const dependencies = {
        ...base,
        // Broadcast member lifecycle on the shared stream as group_agent_*
        // without scopeWorkdir so every device viewing this swarm sees it
        // regardless of solo-chat workdir, and solo-chat listeners ignore it.
        // Progress lines go too, so a working member shows what it is doing;
        // reply text does not, since Swarm replies are not streamed.
        broadcastScope: (type, payload) => {
          const progress = type === 'agent_progress';
          if (
            progress ||
            type === 'agent_start' ||
            type === 'agent_done' ||
            type === 'agent_error' ||
            type === 'agent_cancelled'
          ) {
            sendEvent(`group_${type}`, {
              deviceId: payload.deviceId,
              requestId: payload.requestId,
              agent: agentPayload(payload.agent),
              groupId: group.id,
              ...(progress ? { line: payload.line } : {}),
              createdAt: new Date().toISOString(),
            });
          }
        },
        // The swarm pins each member's model/effort/permission/fast itself, so use
        // its config instead of the member's solo-chat agent-settings store.
        getSettings: (agentKey) =>
          normalizeSettings(agentKey, group.memberConfigs[agentKey] || {}),
        // History lives under the group scope, but the CLI must resume the
        // member's own private group session — not the group scope key.
        runAgent: (agentKey, p, onEvent, opts) =>
          base.runAgent(agentKey, p, onEvent, { ...opts, sessionKey: memberSessionKey }),
      };
      const remote = splitMemberKey(memberKey);
      if (remote) {
        // A remote member runs with its peer's own settings, in the session
        // created for it there.
        const config = group.memberConfigs[memberKey] || {};
        const peer = group.peers[remote.peerId];
        const client = peerClientFor(req, credentials, remote.peerId, peer);
        dependencies.getSettings = () => ({});
        dependencies.runAgent = async (_agentKey, p, onEvent, opts) => {
          if (!client) throw notLinkedError(peer.name);
          return client.chat({
            agent: remote.agentKey,
            sessionId: config.sessionId,
            workdir: config.workdir,
            prompt: p,
            requestId: turnRequestId,
            signal: opts.signal,
            onEvent,
          });
        };
      }
      const result = await runAgentTurn({
        agent: memberAgent,
        agentKey: memberKey,
        contextKey: sessionContextKeyFor(memberKey, runWorkdir),
        // Serialize each member on its own group session key while history
        // lives under the shared group transcript (scopeKey).
        concurrencyKey: memberSessionKey,
        dependencies,
        deviceId,
        historyMetadata: {
          author: memberKey,
          // Record the swarm-scoped display name so the transcript attributes the
          // reply to the member's nickname (falls back to the agent label).
          agentLabel: groupLabelFor(memberKey),
          summonedBy,
          groupId: group.id,
          groupName: group.name,
        },
        // The round notifies once when it ends, not once per member turn.
        prompt: groupPrompt,
        recordHistory: true,
        recordUserMessage: false,
        requestId: turnRequestId,
        responder,
        runState,
        scopeKey,
        session: { id: group.id, name: group.name },
        signal: abortController.signal,
        workdir: runWorkdir,
      });
      return {
        agent: memberKey,
        status: result && result.status,
        summonedBy,
        content: (result && result.content) || '',
      };
    };

    const turns = [];
    // Members a reply named after the last allowed wave, so the app can tell
    // the human why they did not answer.
    let unsummoned = [];
    let lastReply = null;
    try {
      // The human's mentions open the round; each wave runs its summoned
      // members one after another in mention order, then its replies can summon
      // the next wave, up to maxHops waves after the human's.
      let summons = mentions.map((memberKey) => ({
        memberKey,
        summonedBy: HUMAN_AUTHOR,
      }));
      for (let wave = 0; summons.length > 0 && !runState.cancelled; wave += 1) {
        const settled = [];
        for (let index = 0; index < summons.length && !runState.cancelled; index += 1) {
          const plan = planMember(summons[index], wave, index);
          if (!plan) continue;
          const result = await runMember(plan);
          if (result) {
            settled.push(result);
            turns.push({ agent: result.agent, status: result.status });
            if (result.status === 'done') lastReply = result;
          }
        }
        const next = runState.cancelled ? [] : nextSummons(settled);
        summons = wave < maxHops ? next : [];
        if (wave >= maxHops) unsummoned = next.map((item) => item.memberKey);
      }
    } finally {
      runningScopes.delete(scopeKey);
      activeRequests.delete(requestId);
    }

    touchGroup(workspace, group.id);
    // One notification per round, named after the swarm. A stopped round was
    // stopped by someone watching it.
    if (lastReply && !runState.cancelled && typeof notifyTaskCompletion === 'function') {
      notifyTaskCompletion({
        agent: { label: group.name },
        scopeWorkdir: runWorkdir,
        content: lastReply.content,
      });
    }
    const summary = {
      ok: true,
      requestId,
      groupId: group.id,
      cancelled: runState.cancelled,
      turns,
      unsummoned,
    };
    // Broadcast the round's end on the shared stream so every device viewing this
    // group reloads the authoritative transcript — important for agents that emit
    // no streaming deltas (their final reply isn't on the live stream) and for
    // other devices, which never see the POST response.
    sendEvent('group_done', {
      ...summary,
      deviceId,
      createdAt: new Date().toISOString(),
    });
    if (responder.streaming) {
      writeStreamEvent(res, 'group_done', { ...summary, createdAt: new Date().toISOString() });
      endStream(res);
      return undefined;
    }
    return res.json(summary);
  });

  return router;
};
