'use strict';

// Single entry point for the two offline notification channels. Quota resets,
// scheduled-message outcomes, and task-completion alerts all need to reach both
// Web Push and FCM with identical content, so this collapses the repeated
// `push.notify(...).catch(...)` + `fcm.notify(...).catch(...)` pairs into one
// fire-and-forget call. Each channel is a no-op when unconfigured.

const push = require('./push');
const fcm = require('./fcm');

function notifyAll(payload) {
  const tag = (payload && payload.category) || 'notify';
  push
    .notify(payload)
    .catch((err) => console.warn(`[push] ${tag}: ${err.message}`));
  fcm
    .notify(payload)
    .catch((err) => console.warn(`[fcm] ${tag}: ${err.message}`));
}

module.exports = { notifyAll };
