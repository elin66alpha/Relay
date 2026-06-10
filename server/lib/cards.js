'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const { createJsonStore } = require('./json-store');

// Card store for Card Mode suggestions. Persisted to server/cards.json, keyed
// by a flat array under { "cards": [...] }. Cards are scoped by workdir and
// may also point at the source agent session.
const CARDS_FILE = path.join(__dirname, '..', 'cards.json');

const store = createJsonStore(CARDS_FILE, {
  defaultValue: { cards: [] },
  pretty: true,
});

function loadAll() {
  const data = store.load();
  return data && Array.isArray(data.cards) ? data : { cards: [] };
}

function saveAll(data) {
  store.save(data);
}

// Create an empty store on first load if the file does not exist yet.
if (!fs.existsSync(CARDS_FILE)) {
  saveAll({ cards: [] });
}

// Returns pending cards. Deferred cards whose deferUntil has passed are
// promoted back to pending (and persisted) before returning.
function matchesWorkdir(card, workdir) {
  return String((card && card.workdir) || '') === String(workdir || '');
}

function getActiveCards(workdir) {
  const all = loadAll();
  const now = Date.now();
  let changed = false;
  for (const card of all.cards) {
    if (
      card.status === 'deferred' &&
      card.deferUntil &&
      new Date(card.deferUntil).getTime() <= now
    ) {
      card.status = 'pending';
      card.deferUntil = null;
      card.updatedAt = new Date().toISOString();
      changed = true;
    }
  }
  if (changed) saveAll(all);
  return all.cards.filter(
    (c) => c.status === 'pending' && matchesWorkdir(c, workdir),
  );
}

const GESTURE_STATUS = {
  execute: 'executed',
  reject: 'rejected',
  defer: 'deferred',
  irrelevant: 'irrelevant',
};

// Applies a swipe gesture to one card. Returns false for unknown card/gesture.
function applyFeedback(cardId, gesture, deferUntil, workdir) {
  const status = GESTURE_STATUS[gesture];
  if (!status) return false;
  const all = loadAll();
  const card = all.cards.find(
    (c) => c.id === cardId && matchesWorkdir(c, workdir),
  );
  if (!card) return false;
  card.status = status;
  card.deferUntil = gesture === 'defer' ? deferUntil || null : null;
  card.updatedAt = new Date().toISOString();
  saveAll(all);
  return true;
}

// Drops existing pending cards (keeps deferred/executed/etc.), inserts the new
// ones as pending, and persists. Returns the number inserted.
function replaceGeneratedCards(newCards, workdir) {
  const all = loadAll();
  const scopedWorkdir = String(workdir || '').trim();
  const kept = all.cards.filter(
    (c) =>
      c.status !== 'pending' ||
      (String(c.workdir || '') && !matchesWorkdir(c, scopedWorkdir)),
  );
  const now = new Date().toISOString();
  const prepared = (Array.isArray(newCards) ? newCards : []).map((c) => ({
    id: crypto.randomUUID(),
    agentKey: c.agentKey,
    workdir: c.workdir || scopedWorkdir,
    sessionId: c.sessionId || '',
    sessionName: c.sessionName || '',
    title: c.title,
    reason: c.reason || '',
    prompt: c.prompt,
    confidence: typeof c.confidence === 'number' ? c.confidence : 0.6,
    source: c.source || 'chat_history',
    status: 'pending',
    deferUntil: null,
    createdAt: now,
    updatedAt: now,
  }));
  all.cards = [...kept, ...prepared];
  saveAll(all);
  return prepared.length;
}

function pendingCount() {
  return loadAll().cards.filter((c) => c.status === 'pending').length;
}

function pendingCountForWorkdir(workdir) {
  return loadAll().cards.filter(
    (c) => c.status === 'pending' && matchesWorkdir(c, workdir),
  ).length;
}

module.exports = {
  getActiveCards,
  applyFeedback,
  replaceGeneratedCards,
  pendingCount,
  pendingCountForWorkdir,
};
