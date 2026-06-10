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

let admin = null;
try {
  admin = require('firebase-admin');
} catch (_err) {
  admin = null;
}

const TOKENS_FILE = path.join(__dirname, '..', 'fcm-tokens.json');
const SERVICE_ACCOUNT_FILE = String(
  process.env.FCM_SERVICE_ACCOUNT_FILE || '',
).trim();

let app = null;
let configured = false;

if (admin && SERVICE_ACCOUNT_FILE) {
  try {
    const credentialPath = path.resolve(SERVICE_ACCOUNT_FILE);
    const raw = fs.readFileSync(credentialPath, 'utf-8');
    const serviceAccount = JSON.parse(raw);
    app = admin.initializeApp(
      {
        credential: admin.credential.cert(serviceAccount),
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
    return admin.messaging(app).send({
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
  isEnabled,
  addToken,
  removeToken,
  notify,
};
