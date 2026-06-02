'use strict';

// Web Push (VAPID) delivery. Lets quota-reset and scheduled-message alerts reach
// a browser even when the AgentDeck tab is closed — the SSE stream only works
// while a tab is open, so this is the offline path for Web clients.
//
// Graceful degradation: if VAPID keys are not configured the module reports
// disabled and every call is a no-op, so the app behaves exactly as before.
//
// Subscriptions are stored in push-subscriptions.json (secret-ish device state,
// gitignored). Each record is the browser PushSubscription plus the workdir it
// was registered under and the device's language, so scoped alerts only reach
// the right workspace and in the right language.

const fs = require('fs');
const path = require('path');

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

function isEnabled() {
  return configured;
}

function publicKey() {
  return configured ? VAPID_PUBLIC_KEY : '';
}

function loadSubscriptions() {
  try {
    const decoded = JSON.parse(fs.readFileSync(SUBS_FILE, 'utf-8'));
    return Array.isArray(decoded) ? decoded : [];
  } catch (_err) {
    return [];
  }
}

function saveSubscriptions(list) {
  const tmp = `${SUBS_FILE}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(list, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, SUBS_FILE);
}

function subscriptionEndpoint(subscription) {
  return subscription && typeof subscription.endpoint === 'string'
    ? subscription.endpoint
    : '';
}

// Upsert a subscription keyed by its endpoint (re-subscribing the same browser
// updates its workdir/lang rather than creating a duplicate).
function addSubscription({ subscription, workdir, lang }) {
  const endpoint = subscriptionEndpoint(subscription);
  if (!endpoint) return false;
  const record = {
    endpoint,
    keys: (subscription && subscription.keys) || {},
    workdir: String(workdir || ''),
    lang: lang === 'zh' ? 'zh' : 'en',
    updatedAt: new Date().toISOString(),
  };
  const list = loadSubscriptions().filter((item) => item.endpoint !== endpoint);
  list.push(record);
  saveSubscriptions(list);
  return true;
}

function removeSubscription(endpoint) {
  const target = String(endpoint || '').trim();
  if (!target) return false;
  const list = loadSubscriptions();
  const next = list.filter((item) => item.endpoint !== target);
  if (next.length === list.length) return false;
  saveSubscriptions(next);
  return true;
}

// Fire a notification to subscribed browsers. When scopeWorkdir is given only
// subscriptions registered under that workdir receive it (matches the SSE
// scoping); otherwise everyone does (e.g. quota_reset). Best-effort and async;
// gone subscriptions (404/410) are pruned.
async function notify({ title, message, messageZh, scopeWorkdir }) {
  if (!configured) return 0;
  const list = loadSubscriptions();
  if (list.length === 0) return 0;
  const scoped =
    scopeWorkdir != null && scopeWorkdir !== ''
      ? list.filter((item) => item.workdir === scopeWorkdir)
      : list;
  if (scoped.length === 0) return 0;

  const gone = [];
  let sent = 0;
  await Promise.all(
    scoped.map(async (record) => {
      const body =
        record.lang === 'zh' && messageZh ? messageZh : message || messageZh || '';
      const payload = JSON.stringify({
        title: title || 'AgentDeck',
        body,
        tag: 'agentdeck',
      });
      try {
        await webpush.sendNotification(
          { endpoint: record.endpoint, keys: record.keys },
          payload,
        );
        sent += 1;
      } catch (err) {
        const status = err && err.statusCode;
        if (status === 404 || status === 410) {
          gone.push(record.endpoint);
        } else {
          console.warn(
            `[push] send failed (${status || 'error'}): ${err.message}`,
          );
        }
      }
    }),
  );

  if (gone.length > 0) {
    const next = loadSubscriptions().filter(
      (item) => !gone.includes(item.endpoint),
    );
    saveSubscriptions(next);
  }
  return sent;
}

module.exports = {
  isEnabled,
  publicKey,
  addSubscription,
  removeSubscription,
  notify,
};
