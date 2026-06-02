'use strict';

// Firebase Cloud Messaging delivery for mobile clients. This mirrors Web Push:
// quota-reset and scheduled-message alerts can reach Android while the app is
// closed, while missing Firebase configuration degrades to no-op behavior.
//
// Device tokens are stored in fcm-tokens.json (gitignored). Each token carries
// the workdir and language it was registered under so scoped alerts only reach
// the right workspace and use the user's language.

const fs = require('fs');
const path = require('path');

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
      'agentdeck-fcm',
    );
    configured = true;
  } catch (err) {
    console.warn(`[fcm] invalid Firebase configuration: ${err.message}`);
    app = null;
    configured = false;
  }
}

function isEnabled() {
  return configured;
}

function loadTokens() {
  try {
    const decoded = JSON.parse(fs.readFileSync(TOKENS_FILE, 'utf-8'));
    return Array.isArray(decoded) ? decoded : [];
  } catch (_err) {
    return [];
  }
}

function saveTokens(list) {
  const tmp = `${TOKENS_FILE}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(list, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, TOKENS_FILE);
}

function tokenValue(value) {
  return typeof value === 'string' ? value.trim() : '';
}

// Upsert by token so refreshes update workdir/lang instead of duplicating rows.
function addToken({ token, workdir, lang }) {
  if (!configured) return false;
  const id = tokenValue(token);
  if (!id) return false;
  const record = {
    token: id,
    workdir: String(workdir || ''),
    lang: lang === 'zh' ? 'zh' : 'en',
    updatedAt: new Date().toISOString(),
  };
  const list = loadTokens().filter((item) => item.token !== id);
  list.push(record);
  saveTokens(list);
  return true;
}

function removeToken(token) {
  if (!configured) return false;
  const id = tokenValue(token);
  if (!id) return false;
  const list = loadTokens();
  const next = list.filter((item) => item.token !== id);
  if (next.length === list.length) return false;
  saveTokens(next);
  return true;
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

async function notify({ title, message, messageZh, scopeWorkdir }) {
  if (!configured) return 0;
  const list = loadTokens();
  if (list.length === 0) return 0;
  const scoped =
    scopeWorkdir != null && scopeWorkdir !== ''
      ? list.filter((item) => item.workdir === scopeWorkdir)
      : list;
  if (scoped.length === 0) return 0;

  const messaging = admin.messaging(app);
  const invalid = [];
  let sent = 0;
  await Promise.all(
    scoped.map(async (record) => {
      const token = tokenValue(record.token);
      if (!token) return;
      const body =
        record.lang === 'zh' && messageZh ? messageZh : message || messageZh || '';
      const notificationTitle = title || 'AgentDeck';
      try {
        await messaging.send({
          token,
          notification: {
            title: notificationTitle,
            body,
          },
          data: {
            title: notificationTitle,
            body,
            tag: 'agentdeck',
          },
          android: {
            priority: 'high',
            notification: {
              channelId: 'quota_alerts',
              tag: 'agentdeck',
            },
          },
          apns: {
            payload: {
              aps: {
                sound: 'default',
              },
            },
          },
        });
        sent += 1;
      } catch (err) {
        if (invalidTokenError(err)) {
          invalid.push(token);
        } else {
          console.warn(`[fcm] send failed: ${err.message}`);
        }
      }
    }),
  );

  if (invalid.length > 0) {
    const next = loadTokens().filter((item) => !invalid.includes(item.token));
    saveTokens(next);
  }
  return sent;
}

module.exports = {
  isEnabled,
  addToken,
  removeToken,
  notify,
};
