'use strict';

const { spawn } = require('child_process');
const crypto = require('crypto');
const { EventEmitter } = require('events');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { boundedInteger } = require('./bounded-integer');
const { executableInPath } = require('./cli-paths');

const TICKET_TTL_MS = 30 * 1000;
const DEFAULT_IDLE_TIMEOUT_MS = 10 * 60 * 1000;
const MAX_MESSAGE_BYTES = 64 * 1024;
const MAX_TOUCH_POINTS = 5;
const MOUSE_EVENTS = new Set(['mousePressed', 'mouseReleased', 'mouseMoved', 'mouseWheel']);
const MOUSE_BUTTONS = new Set(['none', 'left', 'middle', 'right']);
const TOUCH_EVENTS = new Set(['touchStart', 'touchMove', 'touchEnd', 'touchCancel']);
// Keys a soft keyboard or the hardware-key forwarder can send by name; typed
// characters go through Input.insertText so every IME works.
const NAMED_KEYS = {
  Enter: { code: 'Enter', keyCode: 13, text: '\r' },
  Backspace: { code: 'Backspace', keyCode: 8 },
  Tab: { code: 'Tab', keyCode: 9 },
  Escape: { code: 'Escape', keyCode: 27 },
  Delete: { code: 'Delete', keyCode: 46 },
  Home: { code: 'Home', keyCode: 36 },
  End: { code: 'End', keyCode: 35 },
  PageUp: { code: 'PageUp', keyCode: 33 },
  PageDown: { code: 'PageDown', keyCode: 34 },
  ArrowLeft: { code: 'ArrowLeft', keyCode: 37 },
  ArrowUp: { code: 'ArrowUp', keyCode: 38 },
  ArrowRight: { code: 'ArrowRight', keyCode: 39 },
  ArrowDown: { code: 'ArrowDown', keyCode: 40 },
};

function browserError(message, code) {
  const err = new Error(message);
  err.code = code;
  return err;
}

// Chrome, Chromium or Edge on the backend host; RELAY_BROWSER overrides.
function findBrowser(env = process.env, platform = process.platform) {
  if (env.RELAY_BROWSER) return fs.existsSync(env.RELAY_BROWSER) ? env.RELAY_BROWSER : null;
  let candidates;
  if (platform === 'win32') {
    const roots = [env.PROGRAMFILES, env['PROGRAMFILES(X86)'], env.LOCALAPPDATA].filter(Boolean);
    candidates = roots.flatMap((root) => [
      path.join(root, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      path.join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      path.join(root, 'Chromium', 'Application', 'chrome.exe'),
    ]);
  } else if (platform === 'darwin') {
    candidates = ['Google Chrome', 'Chromium', 'Microsoft Edge'].map(
      (name) => `/Applications/${name}.app/Contents/MacOS/${name}`,
    );
  } else {
    for (const bin of [
      'google-chrome',
      'google-chrome-stable',
      'chromium',
      'chromium-browser',
      'microsoft-edge',
      'microsoft-edge-stable',
    ]) {
      const found = executableInPath(bin);
      if (found) return found;
    }
    // A service manager's PATH often lacks /snap/bin.
    candidates = ['/snap/bin/chromium'];
  }
  return candidates.find((file) => fs.existsSync(file)) || null;
}

// What the address bar accepts: `3000`, `localhost:5173/admin`, or a full
// http(s) URL, always on a loopback host. Pages may still link elsewhere.
function loopbackUrl(input) {
  let text = String(input || '').trim();
  if (/^\d{1,5}([/?#]|$)/.test(text)) text = `localhost:${text}`;
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(text)) text = `http://${text}`;
  let url;
  try {
    url = new URL(text);
  } catch (_err) {
    return null;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
  const host = url.hostname;
  const loopback =
    host === 'localhost' ||
    host.endsWith('.localhost') ||
    host === '[::1]' ||
    /^127(\.\d{1,3}){3}$/.test(host);
  return loopback ? url.href : null;
}

// Headless Chrome driven over --remote-debugging-pipe, so no DevTools port is
// open to other local users. Resolves to one attached page:
// { send(method, params), events (EventEmitter of CDP events, plus 'exit'), close() }.
// The returned Promise's `closed` waits for process exit and profile cleanup, even during startup.
function launchPage(file, { signal, callTimeoutMs = 10000, spawn: spawnBrowser = spawn } = {}) {
  let profile;
  let child;
  try {
    signal?.throwIfAborted();
    profile = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-browser-'));
    const args = [
      '--headless=new',
      '--remote-debugging-pipe',
      `--user-data-dir=${profile}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--mute-audio',
      // A horizontal drag the page is slow to claim (a slider in a busy dev
      // build) would otherwise become Chrome's swipe-back gesture.
      '--disable-features=OverscrollHistoryNavigation',
    ];
    // Chrome refuses to start as root with its sandbox on.
    if (typeof process.getuid === 'function' && process.getuid() === 0) args.push('--no-sandbox');
    child = spawnBrowser(file, args, {
      stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'],
      windowsHide: true,
    });
  } catch (err) {
    try {
      if (profile) fs.rmSync(profile, { recursive: true, force: true });
    } catch (_err) {
      // Preserve the startup error if cleanup itself fails.
    }
    return Promise.reject(browserError(`Could not start the browser: ${err.message}`, 'BROWSER_START_FAILED'));
  }
  const events = new EventEmitter();
  const calls = new Map();
  let nextId = 0;
  let stderr = '';
  let exited = false;
  let closing = false;
  let pageSession = null;
  let pageTargetId = null;
  let resolveClosed;
  const closed = new Promise((resolve) => { resolveClosed = resolve; });

  child.stdio[2].on('data', (chunk) => {
    stderr = (stderr + chunk).slice(-2000);
  });
  let partial = [];
  child.stdio[4].on('data', (chunk) => {
    let start = 0;
    let end;
    while ((end = chunk.indexOf(0, start)) !== -1) {
      partial.push(chunk.subarray(start, end));
      const raw = Buffer.concat(partial).toString('utf8');
      partial = [];
      start = end + 1;
      let message;
      try {
        message = JSON.parse(raw);
      } catch (_err) {
        continue;
      }
      if (message.id) {
        const call = calls.get(message.id);
        calls.delete(message.id);
        if (!call) continue;
        if (message.error) call.reject(new Error(message.error.message));
        else call.resolve(message.result || {});
      } else if (message.sessionId === pageSession || !message.sessionId) {
        // Browser-level events (no session) are only the Target.* ones enabled below.
        events.emit(message.method, message.params || {});
      }
    }
    if (start < chunk.length) partial.push(chunk.subarray(start));
  });
  child.stdio[3].on('error', () => {
    // The exit handler rejects pending calls.
  });

  const removeProfile = () => {
    try {
      fs.rmSync(profile, { recursive: true, force: true });
    } catch (_err) {
      // Windows may keep files locked until the child actually exits.
    }
  };
  const onExit = () => {
    if (exited) return;
    exited = true;
    signal?.removeEventListener('abort', close);
    for (const call of calls.values()) call.reject(new Error('browser exited'));
    calls.clear();
    fs.rm(profile, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 }, resolveClosed);
    events.emit('exit');
  };
  child.on('exit', onExit);
  child.on('error', (err) => {
    stderr += err.message;
    onExit();
  });

  function close() {
    if (exited || closing) return;
    closing = true;
    signal?.removeEventListener('abort', close);
    child.kill('SIGKILL');
    for (const call of calls.values()) call.reject(new Error('browser closed'));
    calls.clear();
    removeProfile();
  }
  signal?.addEventListener('abort', close, { once: true });
  if (signal?.aborted) close();

  function call(method, params = {}, sessionId) {
    if (exited || closing) return Promise.reject(new Error('browser exited'));
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        calls.delete(id);
        reject(new Error(`${method} timed out`));
      }, callTimeoutMs);
      if (typeof timer.unref === 'function') timer.unref();
      calls.set(id, {
        resolve(value) {
          clearTimeout(timer);
          resolve(value);
        },
        reject(err) {
          clearTimeout(timer);
          reject(err);
        },
      });
      child.stdio[3].write(`${JSON.stringify({ id, method, params, sessionId })}\0`);
    });
  }

  const ready = (async () => {
    try {
      const { targetId } = await call('Target.createTarget', { url: 'about:blank' });
      const { sessionId } = await call('Target.attachToTarget', { targetId, flatten: true });
      pageSession = sessionId;
      pageTargetId = targetId;
      // Report tabs a page opens (target=_blank, window.open) so they can be handed off.
      await call('Target.setDiscoverTargets', { discover: true });
    } catch (err) {
      close();
      const detail = stderr.trim().split('\n').slice(-3).join(' ');
      throw browserError(
        `Could not start the browser: ${detail || err.message}`,
        'BROWSER_START_FAILED',
      );
    }
    return {
      send: (method, params) => call(method, params, pageSession),
      sendBrowser: (method, params) => call(method, params),
      targetId: pageTargetId,
      events,
      close,
    };
  })();
  return Object.assign(ready, { closed });
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

// One headless browser per device credential, like the SSH terminal: leaving
// the page keeps it for a while so returning shows the same page.
function createBrowserManager(options = {}) {
  const now = options.now || (() => Date.now());
  const randomTicket =
    options.randomTicket || (() => crypto.randomBytes(32).toString('base64url'));
  const isTokenActive = options.isTokenActive || (() => true);
  const locateBrowser = options.findBrowser || findBrowser;
  const launch = options.launch || launchPage;
  const idleTimeoutMs = options.idleTimeoutMs ?? DEFAULT_IDLE_TIMEOUT_MS;
  const tickets = new Map();
  const sessions = new Map();
  const browserExits = new Set();
  let webSocketServer = null;
  let stopped = false;
  const heartbeatTimer = setInterval(() => {
    for (const session of sessions.values()) {
      if (!isTokenActive(session.tokenId)) {
        destroySession(session);
        continue;
      }
      send(session.client, { type: 'ping' });
    }
  }, 25 * 1000);
  if (typeof heartbeatTimer.unref === 'function') heartbeatTimer.unref();

  function send(client, payload) {
    if (!client || client.readyState !== 1) return;
    try {
      client.send(JSON.stringify(payload));
    } catch (_err) {
      // The socket close handler owns cleanup.
    }
  }

  function createTicket({ tokenId }) {
    if (stopped) throw browserError('Browser is shutting down.', 'BROWSER_UNAVAILABLE');
    const cleanTokenId = String(tokenId || '').trim();
    if (!cleanTokenId) {
      throw browserError('browser token is required', 'BROWSER_UNAUTHORIZED');
    }
    const file = locateBrowser();
    if (!file) {
      throw browserError(
        'No Chrome, Chromium or Edge was found on the backend host. Install one, or set RELAY_BROWSER to its path.',
        'BROWSER_UNAVAILABLE',
      );
    }
    const timestamp = now();
    for (const [key, record] of tickets) {
      if (record.expiresAt <= timestamp) tickets.delete(key);
    }
    const ticket = randomTicket();
    tickets.set(ticket, { tokenId: cleanTokenId, file, expiresAt: timestamp + TICKET_TTL_MS });
    return { ticket, expiresInMs: TICKET_TTL_MS };
  }

  function consumeTicket(ticket) {
    if (stopped) return null;
    const clean = String(ticket || '').trim();
    if (!clean) return null;
    const record = tickets.get(clean);
    tickets.delete(clean);
    if (!record || record.expiresAt <= now() || !isTokenActive(record.tokenId)) return null;
    return record;
  }

  function destroySession(session) {
    if (session.closed) return;
    session.closed = true;
    if (sessions.get(session.tokenId) === session) sessions.delete(session.tokenId);
    if (session.idleTimer) clearTimeout(session.idleTimer);
    session.idleTimer = null;
    const client = session.client;
    session.client = null;
    if (client && client.readyState === 1) client.close(1000, 'browser closed');
    session.abort.abort();
    session.page?.close();
  }

  function closeSession(tokenId) {
    for (const [ticket, record] of tickets) {
      if (record.tokenId === tokenId) tickets.delete(ticket);
    }
    const session = sessions.get(tokenId);
    if (!session) return false;
    destroySession(session);
    return true;
  }

  function wirePage(session, page) {
    page.events.on('Page.screencastFrame', ({ data, sessionId }) => {
      const frame = Buffer.from(String(data || ''), 'base64');
      const ack = () => page.send('Page.screencastFrameAck', { sessionId }).catch(() => {});
      session.lastFrame = frame;
      const client = session.client;
      // Unacked, Chrome pauses the stream: a slow link or no viewer gets fewer frames.
      if (!client || client.readyState !== 1) {
        session.pendingAck = ack;
        return;
      }
      try {
        client.send(frame, { binary: true }, ack);
      } catch (_err) {
        ack();
      }
    });
    page.events.on('Page.frameNavigated', ({ frame }) => {
      if (!frame || frame.parentId) return;
      session.mainFrameId = frame.id;
      session.url = frame.url;
      send(session.client, { type: 'url', url: frame.url });
    });
    page.events.on('Page.navigatedWithinDocument', ({ frameId, url }) => {
      if (frameId !== session.mainFrameId) return;
      session.url = url;
      send(session.client, { type: 'url', url });
    });
    // An unanswered alert/confirm freezes the page, and nobody can answer it remotely.
    page.events.on('Page.javascriptDialogOpening', ({ type, message, defaultPrompt }) => {
      page
        .send('Page.handleJavaScriptDialog', { accept: true, promptText: defaultPrompt || '' })
        .catch(() => {});
      send(session.client, { type: 'dialog', dialogType: type, message: String(message || '') });
    });
    // Reuse the streamed tab for loopback links. External web links open on the device.
    const handedOff = new Set();
    const handOff = (info) => {
      if (!info || info.type !== 'page' || info.targetId === page.targetId) return;
      const url = String(info.url || '');
      if (!url || url === 'about:blank' || handedOff.has(info.targetId)) return;
      handedOff.add(info.targetId);
      page.sendBrowser('Target.closeTarget', { targetId: info.targetId }).catch(() => {});
      if (!/^https?:\/\//i.test(url)) return;
      const local = loopbackUrl(url);
      if (local) page.send('Page.navigate', { url: local }).catch(() => {});
      else send(session.client, { type: 'open', url });
    };
    page.events.on('Target.targetCreated', ({ targetInfo }) => handOff(targetInfo));
    page.events.on('Target.targetInfoChanged', ({ targetInfo }) => handOff(targetInfo));
    page.events.on('exit', () => {
      send(session.client, { type: 'exit' });
      destroySession(session);
    });
  }

  function startSession(ticket) {
    const session = {
      tokenId: ticket.tokenId,
      client: null,
      page: null,
      abort: new AbortController(),
      closed: false,
      url: 'about:blank',
      mainFrameId: null,
      lastFrame: null,
      pendingAck: null,
      idleTimer: null,
    };
    const launching = launch(ticket.file, { signal: session.abort.signal });
    if (launching.closed) {
      browserExits.add(launching.closed);
      launching.closed.then(() => browserExits.delete(launching.closed));
    }
    session.ready = launching.then(async (page) => {
      session.page = page;
      if (session.closed) {
        page.close();
        throw new Error('browser closed');
      }
      await page.send('Page.enable');
      await page.send('Page.startScreencast', { format: 'jpeg', quality: 70 });
      wirePage(session, page);
      return page;
    });
    session.ready.catch(() => {
      if (sessions.get(session.tokenId) === session) sessions.delete(session.tokenId);
      session.closed = true;
      session.abort.abort();
      session.page?.close();
    });
    sessions.set(ticket.tokenId, session);
    return session;
  }

  function handleMessage(session, client, message) {
    const page = session.page;
    if (!page || !message || typeof message !== 'object') return;
    const run = (method, params) => page.send(method, params).catch(() => {});
    switch (message.type) {
      case 'navigate': {
        const url = loopbackUrl(message.url);
        if (!url) {
          send(client, {
            type: 'rejected',
            message: 'Only localhost and 127.0.0.1 addresses can be opened here.',
          });
          return;
        }
        run('Page.navigate', { url });
        return;
      }
      case 'back':
        run('Runtime.evaluate', { expression: 'history.back()' });
        return;
      case 'reload':
        run('Page.reload', {});
        return;
      case 'resize': {
        const width = boundedInteger(message.width, 0, 100, 4096);
        const height = boundedInteger(message.height, 0, 100, 4096);
        if (!width || !height) return;
        const scale = Math.min(Math.max(finiteNumber(message.scale) || 1, 1), 2);
        const mobile = message.mobile === true;
        run('Emulation.setDeviceMetricsOverride', {
          width,
          height,
          deviceScaleFactor: scale,
          mobile,
        });
        run('Emulation.setTouchEmulationEnabled', {
          enabled: mobile,
          maxTouchPoints: MAX_TOUCH_POINTS,
        });
        return;
      }
      case 'mouse': {
        const x = finiteNumber(message.x);
        const y = finiteNumber(message.y);
        if (!MOUSE_EVENTS.has(message.event) || x === null || y === null) return;
        run('Input.dispatchMouseEvent', {
          type: message.event,
          x,
          y,
          button: MOUSE_BUTTONS.has(message.button) ? message.button : 'none',
          buttons: boundedInteger(message.buttons, 0, 0, 31),
          clickCount: boundedInteger(message.clickCount, 0, 0, 3),
          deltaX: finiteNumber(message.deltaX) || 0,
          deltaY: finiteNumber(message.deltaY) || 0,
          modifiers: boundedInteger(message.modifiers, 0, 0, 15),
        });
        return;
      }
      case 'touch': {
        if (!TOUCH_EVENTS.has(message.event) || !Array.isArray(message.points)) return;
        const touchPoints = [];
        for (const point of message.points.slice(0, MAX_TOUCH_POINTS)) {
          const x = finiteNumber(point && point.x);
          const y = finiteNumber(point && point.y);
          if (x === null || y === null) return;
          touchPoints.push({ x, y, id: boundedInteger(point.id, 0, 0, 1000) });
        }
        run('Input.dispatchTouchEvent', { type: message.event, touchPoints });
        return;
      }
      case 'text': {
        const text = typeof message.text === 'string' ? message.text : '';
        if (text) run('Input.insertText', { text });
        return;
      }
      case 'key': {
        const key = Object.hasOwn(NAMED_KEYS, message.key) ? NAMED_KEYS[message.key] : null;
        if (!key) return;
        const base = {
          key: message.key,
          code: key.code,
          windowsVirtualKeyCode: key.keyCode,
          modifiers: boundedInteger(message.modifiers, 0, 0, 15),
        };
        run('Input.dispatchKeyEvent', {
          ...base,
          type: key.text ? 'keyDown' : 'rawKeyDown',
          ...(key.text ? { text: key.text } : {}),
        });
        run('Input.dispatchKeyEvent', { ...base, type: 'keyUp' });
        return;
      }
      default:
    }
  }

  async function attachClient(ticket, client) {
    client.on('error', () => {
      // ws emits close after error; cleanup happens there.
    });
    if (stopped) {
      send(client, { type: 'error', code: 'BROWSER_UNAVAILABLE', message: 'Browser is shutting down.' });
      if (client.readyState === 1) client.close(1001, 'browser closed');
      return;
    }
    const session = sessions.get(ticket.tokenId) || startSession(ticket);
    if (session.idleTimer) clearTimeout(session.idleTimer);
    session.idleTimer = null;
    const previous = session.client;
    session.client = client;
    if (previous && previous !== client) {
      send(previous, { type: 'replaced' });
      previous.close(4001, 'browser opened elsewhere');
    }
    client.on('message', (raw, isBinary) => {
      if (isBinary || session.client !== client) return;
      let message;
      try {
        message = JSON.parse(String(raw));
      } catch (_err) {
        return;
      }
      handleMessage(session, client, message);
    });
    client.on('close', () => {
      if (session.closed || session.client !== client) return;
      session.client = null;
      if (session.idleTimer) clearTimeout(session.idleTimer);
      session.idleTimer = setTimeout(() => {
        if (!session.client) destroySession(session);
      }, idleTimeoutMs);
      if (typeof session.idleTimer.unref === 'function') session.idleTimer.unref();
    });
    try {
      await session.ready;
    } catch (err) {
      send(client, { type: 'error', code: err.code || 'BROWSER_START_FAILED', message: err.message });
      if (client.readyState === 1) client.close(1011, 'browser unavailable');
      return;
    }
    if (session.client !== client) return;
    send(client, { type: 'ready', url: session.url });
    if (session.lastFrame) {
      try {
        client.send(session.lastFrame, { binary: true });
      } catch (_err) {
        // The close handler owns cleanup.
      }
    }
    const ack = session.pendingAck;
    session.pendingAck = null;
    if (ack) ack();
  }

  // Returns false for paths it does not own, so the server can try other handlers.
  function handleUpgrade(req, socket, head, url) {
    if (url.pathname !== '/api/browser/connect') return false;
    const ticket = consumeTicket(url.searchParams.get('ticket'));
    if (!ticket) {
      try {
        socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
      } finally {
        socket.destroy();
      }
      return true;
    }
    if (!webSocketServer) {
      const { WebSocketServer } = require('ws');
      webSocketServer = new WebSocketServer({
        noServer: true,
        perMessageDeflate: false,
        maxPayload: MAX_MESSAGE_BYTES,
      });
    }
    webSocketServer.handleUpgrade(req, socket, head, (client) => {
      attachClient(ticket, client);
    });
    return true;
  }

  async function closeAll() {
    stopped = true;
    clearInterval(heartbeatTimer);
    for (const session of [...sessions.values()]) destroySession(session);
    tickets.clear();
    if (webSocketServer) {
      webSocketServer.close();
      webSocketServer = null;
    }
    let timeout;
    try {
      // Wait for Windows to release profile files, but never block backend shutdown indefinitely.
      await Promise.race([
        Promise.allSettled([...browserExits]),
        new Promise((resolve) => {
          timeout = setTimeout(resolve, 3000);
          if (typeof timeout.unref === 'function') timeout.unref();
        }),
      ]);
    } finally {
      clearTimeout(timeout);
    }
  }

  return {
    attachClient,
    closeAll,
    closeSession,
    consumeTicket,
    createTicket,
    handleUpgrade,
  };
}

module.exports = {
  createBrowserManager,
  findBrowser,
  launchPage,
  loopbackUrl,
};
