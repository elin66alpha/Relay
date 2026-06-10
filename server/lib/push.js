'use strict';

// Web Push (VAPID) delivery. Lets quota-reset and scheduled-message alerts reach
// a browser even when the Relay tab is closed — the SSE stream only works
// while a tab is open, so this is the offline path for Web clients.
//
// Graceful degradation: if VAPID keys are not configured the module reports
// disabled and every call is a no-op, so the app behaves exactly as before.
//
// Subscriptions are stored in push-subscriptions.json (secret-ish device state,
// gitignored) via the shared subscription-store, which handles the workdir/
// category scoping, parallel fan-out, and pruning of gone endpoints.

const path = require('path');

const { createSubscriptionStore, normalizeCategories } = require('./subscription-store');

let webpush = null;
try {
  webpush = require('web-push');
} catch (_err) {
  webpush = null;
}

const SUBS_FILE = path.join(__dirname, '..', 'push-subscriptions.json');

const VAPID_PUBLIC_KEY = String(process.env.VAPID_PUBLIC_KEY || '').trim();
const VAPID_PRIVATE_KEY = String(process.env.VAPID_PRIVATE_KEY || '').trim();
const VAPID_SUBJECT = String(
  process.env.VAPID_SUBJECT || 'mailto:admin@example.com',
).trim();

let configured = false;
if (webpush && VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY) {
  try {
    webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
    configured = true;
  } catch (err) {
    console.warn(`[push] invalid VAPID configuration: ${err.message}`);
    configured = false;
  }
}

const store = createSubscriptionStore({
  filePath: SUBS_FILE,
  key: 'endpoint',
  send(record, { title, body, tag }) {
    const payload = JSON.stringify({ title, body, tag });
    return webpush.sendNotification(
      { endpoint: record.endpoint, keys: record.keys },
      payload,
    );
  },
  isGone(err) {
    const status = err && err.statusCode;
    if (status === 404 || status === 410) return true;
    console.warn(`[push] send failed (${status || 'error'}): ${err.message}`);
    return false;
  },
});

function isEnabled() {
  return configured;
}

function publicKey() {
  return configured ? VAPID_PUBLIC_KEY : '';
}

function subscriptionEndpoint(subscription) {
  return subscription && typeof subscription.endpoint === 'string'
    ? subscription.endpoint
    : '';
}

function addSubscription({ subscription, workdir, lang, categories }) {
  const endpoint = subscriptionEndpoint(subscription);
  if (!endpoint) return false;
  return store.upsert({
    endpoint,
    keys: (subscription && subscription.keys) || {},
    workdir: String(workdir || ''),
    lang: lang === 'zh' ? 'zh' : 'en',
    categories: normalizeCategories(categories),
    updatedAt: new Date().toISOString(),
  });
}

function removeSubscription(endpoint) {
  return store.remove(endpoint);
}

async function notify(payload) {
  if (!configured) return 0;
  return store.notify(payload);
}

module.exports = {
  isEnabled,
  publicKey,
  addSubscription,
  removeSubscription,
  notify,
};
