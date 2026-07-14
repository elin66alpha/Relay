'use strict';

const express = require('express');

module.exports = function createTerminalRouter(ctx) {
  const { bearerToken, terminalManager, tokenRecordForToken } = ctx;
  const router = express.Router();

  router.post('/api/terminal/ticket', (req, res) => {
    const tokenRecord = tokenRecordForToken(bearerToken(req));
    if (!tokenRecord || tokenRecord.revoked) {
      return res.status(401).json({ error: 'unauthorized' });
    }
    try {
      const result = terminalManager.createTicket({
        tokenId: tokenRecord.id,
        cols: (req.body || {}).cols,
        rows: (req.body || {}).rows,
      });
      return res.json({ ok: true, ...result });
    } catch (err) {
      return res.status(err.code === 'TERMINAL_UNAVAILABLE' ? 503 : 500).json({
        error: err.message,
        code: err.code || 'TERMINAL_ERROR',
      });
    }
  });

  return router;
};
