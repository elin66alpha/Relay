'use strict';

const QUIET_MS = 800;

// Drops colour/cursor escape sequences so the model reads plain shell output.
function plainText(text) {
  return String(text || '')
    // eslint-disable-next-line no-control-regex
    .replace(/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/g, '')
    // eslint-disable-next-line no-control-regex
    .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
    // eslint-disable-next-line no-control-regex
    .replace(/\x1b[@-_]/g, '')
    .replace(/\r\n/g, '\n')
    // eslint-disable-next-line no-control-regex
    .replace(/[\x00-\x08\x0b-\x1f\x7f]/g, '');
}

// One call against this token's resumable PTY: attach, optionally type input,
// collect output until it goes quiet or waitMs passes, then detach. The shell
// keeps running between calls, as it does when the app's terminal screen closes.
async function runTerminal(client, { input, waitMs }) {
  const { ticket } = await client.json('/api/terminal/ticket', {
    method: 'POST',
    body: { cols: 160, rows: 48 },
  });
  const url = new URL('/api/terminal/connect', client.baseUrl);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  url.searchParams.set('ticket', ticket);
  const socket = new WebSocket(url);
  let replay = '';
  let output = '';
  let ended = '';
  return new Promise((resolve, reject) => {
    let quietTimer = null;
    const finish = () => {
      clearTimeout(quietTimer);
      clearTimeout(deadline);
      try {
        socket.close();
      } catch (_err) {
        // Already closed.
      }
      resolve({ replay: plainText(replay), output: plainText(output), ended });
    };
    const deadline = setTimeout(finish, waitMs);
    const quiet = () => {
      clearTimeout(quietTimer);
      quietTimer = setTimeout(finish, QUIET_MS);
    };
    socket.addEventListener('message', (event) => {
      let message;
      try {
        message = JSON.parse(String(event.data));
      } catch (_err) {
        return;
      }
      if (message.type === 'output') {
        if (message.replay) replay += message.data;
        else output += message.data;
        quiet();
      } else if (message.type === 'ready') {
        if (input) socket.send(JSON.stringify({ type: 'input', data: input }));
        quiet();
      } else if (message.type === 'exit' || message.type === 'replaced' || message.type === 'error') {
        ended = message.type === 'error' ? `${message.code}: ${message.message}` : message.type;
        finish();
      }
    });
    socket.addEventListener('error', () => {
      clearTimeout(deadline);
      clearTimeout(quietTimer);
      reject(new Error('terminal connection failed'));
    });
    socket.addEventListener('close', () => {
      if (!ended) ended = 'closed';
      finish();
    });
  });
}

module.exports = { runTerminal, plainText };
