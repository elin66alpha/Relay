'use strict';

const { listAgents } = require('./agents');
const { LEGACY_SESSION_ID, listChatSessions } = require('./chat-sessions');
const { historyScopesFor } = require('./history');

// Generates candidate suggestion cards from existing chat history. No ML —
// keyword matching only. Reads the same scoped history that GET /api/history
// serves: `workdir\0agentKey[\0sessionId]`.
const RECENT_LIMIT = 60;
const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;
const SCOPE_SEPARATOR = '\u0000';
const MAX_CARDS_PER_WORKDIR = 12;

function contextKeyFor(workdir, agentKey) {
  return `${workdir}${SCOPE_SEPARATOR}${agentKey}`;
}

function sessionNameFor(workdir, agentKey, sessionId) {
  const id = sessionId || LEGACY_SESSION_ID;
  try {
    const context = listChatSessions(contextKeyFor(workdir, agentKey));
    const match = context.sessions.find((session) => session.id === id);
    return match ? match.name : id;
  } catch (_err) {
    return id === LEGACY_SESSION_ID ? 'Main' : id;
  }
}

// Most recent messages for one concrete workdir+agent+session scope, oldest-first.
function recentMessagesForScope(scope, limit = RECENT_LIMIT) {
  const messages = Array.isArray(scope && scope.messages)
    ? scope.messages.slice()
    : [];
  messages.sort((a, b) =>
    String(a.createdAt || '').localeCompare(String(b.createdAt || '')),
  );
  return messages.slice(-limit);
}

function hasLongCodeBlock(text, minLines) {
  const re = /```[\s\S]*?```/g;
  let match;
  while ((match = re.exec(text)) !== null) {
    if (match[0].split('\n').length > minLines) return true;
  }
  return false;
}

// Generates up to 4 cards for one workdir+agent+session from its recent history.
function generateCardsForScope(scope) {
  const agentKey = scope.agentKey;
  const workdir = scope.workdir;
  const sessionId = scope.sessionId || LEGACY_SESSION_ID;
  const sessionName = sessionNameFor(workdir, agentKey, sessionId);
  const messages = recentMessagesForScope(scope, RECENT_LIMIT);
  if (messages.length === 0) return [];

  const text = messages.map((m) => String(m.content || '')).join('\n');
  const cards = [];
  const base = {
    agentKey,
    workdir,
    sessionId,
    sessionName,
  };

  if (/error|exception|traceback|TypeError|NullPointer|undefined is not/i.test(text)) {
    cards.push({
      ...base,
      title: 'Debug recent error',
      reason: 'An error or exception showed up in your recent conversation.',
      prompt: 'Review the error in our recent conversation and suggest a fix',
      confidence: 0.88,
      source: 'chat_history',
    });
  }

  const cutoff = Date.now() - SEVEN_DAYS_MS;
  const ranTestsRecently = messages.some((m) => {
    if (!/npm test|pytest|go test|cargo test/i.test(String(m.content || ''))) {
      return false;
    }
    const t = new Date(m.createdAt || 0).getTime();
    return Number.isFinite(t) && t >= cutoff;
  });
  if (ranTestsRecently) {
    cards.push({
      ...base,
      title: 'Run tests again',
      reason: 'You ran the test suite recently.',
      prompt: 'Run the test suite and summarize any failures',
      confidence: 0.82,
      source: 'chat_history',
    });
  }

  if (hasLongCodeBlock(text, 20)) {
    cards.push({
      ...base,
      title: 'Explain this code',
      reason: 'A long code block was shared recently.',
      prompt: 'Explain the code we discussed recently, section by section',
      confidence: 0.76,
      source: 'chat_history',
    });
  }

  if (/[^\s]*[/\\][^\s]*\.[A-Za-z0-9]{1,8}(\s|$)/m.test(text)) {
    cards.push({
      ...base,
      title: 'Review recent file changes',
      reason: 'File paths came up in your recent conversation.',
      prompt: 'Review the file changes we discussed and suggest improvements',
      confidence: 0.72,
      source: 'chat_history',
    });
  }

  if (cards.length === 0) {
    cards.push({
      ...base,
      title: 'Summarize our session',
      reason: 'A quick recap of your recent session.',
      prompt:
        'Summarize what we accomplished in this session and list any open tasks',
      confidence: 0.6,
      source: 'chat_history',
    });
  }

  return cards.slice(0, 4);
}

function generateCardsForWorkdir(workdir) {
  const targetWorkdir = String(workdir || '').trim();
  if (!targetWorkdir) return [];
  const agentKeys = new Set(listAgents().map((agent) => agent.key));
  const all = [];
  for (const scope of historyScopesFor({ workdir: targetWorkdir })) {
    if (!agentKeys.has(scope.agentKey)) continue;
    all.push(...generateCardsForScope(scope));
  }
  all.sort((a, b) => (b.confidence || 0) - (a.confidence || 0));
  return all.slice(0, MAX_CARDS_PER_WORKDIR);
}

module.exports = { generateCardsForScope, generateCardsForWorkdir };
