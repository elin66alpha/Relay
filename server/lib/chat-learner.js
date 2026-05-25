'use strict';

const fs = require('fs');
const path = require('path');

const { listAgents } = require('./agents');

// Generates candidate suggestion cards from existing chat history. No ML —
// keyword matching only. Reads the same chat-history.json that GET /api/history
// serves; history is keyed by `deviceId:agentKey`, so for a given agent we
// merge messages across all devices.
const HISTORY_FILE = path.join(__dirname, '..', 'chat-history.json');
const RECENT_LIMIT = 60;
const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;

function loadHistory() {
  try {
    return JSON.parse(fs.readFileSync(HISTORY_FILE, 'utf-8'));
  } catch (_err) {
    return {};
  }
}

// Most recent messages for one agent across all devices, oldest-first.
function recentMessagesFor(agentKey, limit = RECENT_LIMIT) {
  const all = loadHistory();
  const messages = [];
  for (const [scopeKey, list] of Object.entries(all)) {
    if (!Array.isArray(list)) continue;
    if (!scopeKey.endsWith(`:${agentKey}`)) continue;
    for (const m of list) messages.push(m);
  }
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

// Generates up to 4 cards for one agent from its recent history.
function generateCards(agentKey) {
  const messages = recentMessagesFor(agentKey, RECENT_LIMIT);
  if (messages.length === 0) return [];

  const text = messages.map((m) => String(m.content || '')).join('\n');
  const cards = [];

  if (/error|exception|traceback|TypeError|NullPointer|undefined is not/i.test(text)) {
    cards.push({
      agentKey,
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
      agentKey,
      title: 'Run tests again',
      reason: 'You ran the test suite recently.',
      prompt: 'Run the test suite and summarize any failures',
      confidence: 0.82,
      source: 'chat_history',
    });
  }

  if (hasLongCodeBlock(text, 20)) {
    cards.push({
      agentKey,
      title: 'Explain this code',
      reason: 'A long code block was shared recently.',
      prompt: 'Explain the code we discussed recently, section by section',
      confidence: 0.76,
      source: 'chat_history',
    });
  }

  if (/[^\s]*[/\\][^\s]*\.[A-Za-z0-9]{1,8}(\s|$)/m.test(text)) {
    cards.push({
      agentKey,
      title: 'Review recent file changes',
      reason: 'File paths came up in your recent conversation.',
      prompt: 'Review the file changes we discussed and suggest improvements',
      confidence: 0.72,
      source: 'chat_history',
    });
  }

  if (cards.length === 0) {
    cards.push({
      agentKey,
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

function generateCardsForAllAgents() {
  const all = [];
  for (const agent of listAgents()) {
    all.push(...generateCards(agent.key));
  }
  return all;
}

module.exports = { generateCards, generateCardsForAllAgents };
