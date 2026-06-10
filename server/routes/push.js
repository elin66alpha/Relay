'use strict';

const express = require('express');

module.exports = function createPushRouter(ctx) {
  const {
    fcm,
    push,
    pushCategoriesFromBody,
    requestWorkdir,
  } = ctx;
  const router = express.Router();

  router.get('/api/push/config', (_req, res) => {
    res.json({ enabled: push.isEnabled(), publicKey: push.publicKey() });
  });

  router.post('/api/push/subscribe', (req, res) => {
    const subscription = req.body && req.body.subscription;
    if (!subscription || !subscription.endpoint) {
      return res.status(400).json({ error: 'subscription is required' });
    }
    let workdir = '';
    try {
      workdir = requestWorkdir(req);
    } catch (_err) {
      workdir = '';
    }
    push.addSubscription({
      subscription,
      workdir,
      lang: req.body && req.body.lang,
      categories: pushCategoriesFromBody(req.body),
    });
    res.json({ ok: true });
  });

  router.post('/api/push/unsubscribe', (req, res) => {
    const endpoint = req.body && req.body.endpoint;
    push.removeSubscription(endpoint);
    res.json({ ok: true });
  });

  router.post('/api/push/fcm/register', (req, res) => {
    const token = req.body && req.body.token;
    if (!token || typeof token !== 'string') {
      return res.status(400).json({ error: 'token is required' });
    }
    let workdir = '';
    try {
      workdir = requestWorkdir(req);
    } catch (_err) {
      workdir = '';
    }
    fcm.addToken({
      token,
      workdir,
      lang: req.body && req.body.lang,
      categories: pushCategoriesFromBody(req.body),
    });
    return res.json({ ok: true, enabled: fcm.isEnabled() });
  });

  router.post('/api/push/fcm/unregister', (req, res) => {
    const token = req.body && req.body.token;
    fcm.removeToken(token);
    res.json({ ok: true, enabled: fcm.isEnabled() });
  });

  return router;
};
