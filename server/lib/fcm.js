'use strict';

// Firebase Cloud Messaging delivery for mobile clients. This mirrors Web Push:
// quota-reset and scheduled-message alerts can reach Android while the app is
// closed, while missing Firebase configuration degrades to no-op behavior.
//
// Device tokens are stored in fcm-tokens.json (gitignored) via the shared
// subscription-store, which handles the workdir/category scoping, parallel
// fan-out, and pruning of invalid tokens.

const fs = require('fs');
const path = require('path');

const { createSubscriptionStore, normalizeCategories } = require('./subscription-store');

let firebaseApp = null;
let getMessaging = null;
try {
  firebaseApp = require('firebase-admin/app');
  ({ getMessaging } = require('firebase-admin/messaging'));
} catch (_err) {
  firebaseApp = null;
}

const TOKENS_FILE = path.join(__dirname, '..', 'fcm-tokens.json');
const configuredServiceAccount = String(
  process.env.FCM_SERVICE_ACCOUNT_FILE || '',
).trim();
// Absolute, or '' when FCM is not configured. The file API denies it.
const SERVICE_ACCOUNT_FILE = configuredServiceAccount
  ? path.resolve(configuredServiceAccount)
  : '';

let app = null;
let configured = false;

if (firebaseApp && SERVICE_ACCOUNT_FILE) {
  try {
    const raw = fs.readFileSync(SERVICE_ACCOUNT_FILE, 'utf-8');
    const serviceAccount = JSON.parse(raw);
    app = firebaseApp.initializeApp(
      {
        credential: firebaseApp.cert(serviceAccount),
      },
      'relay-fcm',
    );
    configured = true;
  } catch (err) {
    console.warn(`[fcm] invalid Firebase configuration: ${err.message}`);
    app = null;
    configured = false;
  }
}

function invalidTokenError(err) {
  const code = String(
    (err && err.errorInfo && err.errorInfo.code) || (err && err.code) || '',
  );
  return (
    code === 'messaging/registration-token-not-registered' ||
    code === 'messaging/invalid-registration-token' ||
    code === 'messaging/invalid-argument'
  );
}

const store = createSubscriptionStore({
  filePath: TOKENS_FILE,
  key: 'token',
  send(record, { title, body, tag }) {
    return getMessaging(app).send({
      token: record.token,
      notification: { title, body },
      data: { title, body, tag },
      android: {
        priority: 'high',
        notification: { channelId: 'quota_alerts', tag },
      },
      apns: {
        payload: { aps: { sound: 'default' } },
      },
    });
  },
  isGone(err) {
    if (invalidTokenError(err)) return true;
    console.warn(`[fcm] send failed: ${err.message}`);
    return false;
  },
});

function isEnabled() {
  return configured;
}

function tokenValue(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function addToken({ token, workdir, lang, categories }) {
  if (!configured) return false;
  const id = tokenValue(token);
  if (!id) return false;
  return store.upsert({
    token: id,
    workdir: String(workdir || ''),
    lang: lang === 'zh' ? 'zh' : 'en',
    categories: normalizeCategories(categories),
    updatedAt: new Date().toISOString(),
  });
}

function removeToken(token) {
  if (!configured) return false;
  return store.remove(tokenValue(token));
}

async function notify(payload) {
  if (!configured) return 0;
  return store.notify(payload);
}

module.exports = {
  SERVICE_ACCOUNT_FILE,
  isEnabled,
  addToken,
  removeToken,
  notify,
};
