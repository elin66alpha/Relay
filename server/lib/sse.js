'use strict';

function wantsStream(req) {
  return String(req.get('accept') || '')
    .toLowerCase()
    .includes('text/event-stream');
}

function writeStreamEvent(res, type, payload) {
  if (res.destroyed || res.writableEnded) return;
  try {
    res.write(`event: ${type}\ndata: ${JSON.stringify(payload)}\n\n`);
  } catch (_err) {
    // The client may have closed the app/web tab while the CLI keeps running.
  }
}

function endStream(res) {
  if (res.destroyed || res.writableEnded) return;
  try {
    res.end();
  } catch (_err) {
    // The request can already be gone; the server-side run still finishes.
  }
}

module.exports = { wantsStream, writeStreamEvent, endStream };
