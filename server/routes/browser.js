'use strict';

const express = require('express');

module.exports = function createBrowserRouter(ctx) {
  const { bearerToken, browserManager, tokenRecordForToken } = ctx;
  const router = express.Router();

  router.post('/api/browser/ticket', (req, res) => {
    const tokenRecord = tokenRecordForToken(bearerToken(req));
    if (!tokenRecord || tokenRecord.revoked) {
      return res.status(401).json({ error: 'unauthorized' });
    }
    try {
      return res.json({ ok: true, ...browserManager.createTicket({ tokenId: tokenRecord.id }) });
    } catch (err) {
      return res.status(err.code === 'BROWSER_UNAVAILABLE' ? 503 : 500).json({
        error: err.message,
        code: err.code || 'BROWSER_ERROR',
      });
    }
  });

  return router;
};
