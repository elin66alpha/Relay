'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const http = require('node:http');
const { PassThrough, Writable } = require('node:stream');
const { after, before, test } = require('node:test');
const express = require('express');

const {
  createBrowserManager,
  findBrowser,
  launchPage,
  loopbackUrl,
} = require('../lib/browser-manager');
const createBrowserRouter = require('../routes/browser');
const createMetaRouter = require('../routes/meta');

class FakeClient extends EventEmitter {
  constructor() {
    super();
    this.readyState = 1;
    this.json = [];
    this.frames = [];
  }

  send(data, _options, callback) {
    if (Buffer.isBuffer(data)) this.frames.push(data);
    else this.json.push(JSON.parse(data));
    if (callback) callback();
  }

  close(code) {
    this.closeCode = code;
    this.readyState = 3;
    this.emit('close');
  }
}

function fakePage() {
  const page = {
    calls: [],
    events: new EventEmitter(),
    closed: false,
    targetId: 'main-target',
    send(method, params) {
      page.calls.push([method, params]);
      return Promise.resolve({});
    },
    sendBrowser(method, params) {
      page.calls.push([method, params]);
      return Promise.resolve({});
    },
    close() {
      page.closed = true;
    },
  };
  return page;
}

function managerWithFakePage(options = {}) {
  const page = fakePage();
  const launched = [];
  const manager = createBrowserManager({
    findBrowser: () => '/fake/chrome',
    launch: async (file) => {
      launched.push(file);
      return page;
    },
    ...options,
  });
  return { manager, page, launched };
}

async function attached(manager, client = new FakeClient()) {
  const { ticket } = manager.createTicket({ tokenId: 'token-1' });
  await manager.attachClient(manager.consumeTicket(ticket), client);
  return client;
}

function lastCall(page, method) {
  return page.calls.filter(([name]) => name === method).at(-1)?.[1];
}

function fakeBrowser(stallAt) {
  const child = new EventEmitter();
  const requests = [];
  child.stdio = [null, null, new PassThrough(), new Writable({
    write(raw, _encoding, done) {
      const request = JSON.parse(String(raw).replace(/\0$/, ''));
      requests.push(request.method);
      if (request.method !== stallAt) {
        queueMicrotask(() => child.stdio[4].write(`${JSON.stringify({
          id: request.id,
          result: { targetId: 'target', sessionId: 'page-session' },
        })}\0`));
      }
      done();
    },
  }), new PassThrough()];
  child.kill = (signal) => {
    child.signal = signal;
    // Resource cleanup must also work before the OS reports the exit.
    setImmediate(() => child.emit('exit'));
    return true;
  };
  return {
    child,
    requests,
    spawn(_file, args) {
      child.profile = args.find((arg) => arg.startsWith('--user-data-dir=')).slice('--user-data-dir='.length);
      return child;
    },
  };
}

test('shutdown closes an already ready page synchronously', async () => {
  const { manager, page } = managerWithFakePage();
  await attached(manager);
  const stopped = manager.closeAll();
  assert.equal(page.closed, true);
  await stopped;
});

test('shutdown aborts a browser still starting and waits for profile cleanup', async () => {
  const browser = fakeBrowser('Target.createTarget');
  const { manager } = managerWithFakePage({
    launch: (file, options) => launchPage(file, { ...options, spawn: browser.spawn }),
  });
  const attaching = attached(manager);
  assert.equal(fs.existsSync(browser.child.profile), true);
  let exited = false;
  browser.child.once('exit', () => { exited = true; });
  const stopped = manager.closeAll();
  assert.equal(browser.child.signal, 'SIGKILL');
  assert.equal(fs.existsSync(browser.child.profile), false);
  const client = await attaching;
  assert.equal(client.json.some((message) => message.type === 'ready'), false);
  await stopped;
  assert.equal(exited, true);
  assert.equal(fs.existsSync(browser.child.profile), false);
});

test('synchronous browser spawn failures reject normally and remove the profile', async () => {
  let profile;
  const { manager } = managerWithFakePage({
    launch: (file, options) => launchPage(file, {
      ...options,
      spawn(_file, args) {
        profile = args.find((arg) => arg.startsWith('--user-data-dir=')).slice('--user-data-dir='.length);
        throw new Error('spawn failed synchronously');
      },
    }),
  });
  const client = await attached(manager);
  assert.deepEqual(client.json[0], {
    type: 'error',
    code: 'BROWSER_START_FAILED',
    message: 'Could not start the browser: spawn failed synchronously',
  });
  assert.equal(client.closeCode, 1011);
  assert.equal(fs.existsSync(profile), false);
  await manager.closeAll();
});

test('shutdown has a deadline if the OS never reports browser exit', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const browser = fakeBrowser('Target.createTarget');
  browser.child.kill = (signal) => { browser.child.signal = signal; return true; };
  const { manager } = managerWithFakePage({
    launch: (file, options) => launchPage(file, { ...options, spawn: browser.spawn }),
  });
  const attaching = attached(manager);
  const stopped = manager.closeAll();
  t.mock.timers.tick(3000);
  await stopped;
  assert.equal(browser.child.signal, 'SIGKILL');
  browser.child.emit('exit');
  await attaching;
});

test('shutdown refuses new browser sessions while process cleanup is still pending', async () => {
  const browser = fakeBrowser('Target.createTarget');
  browser.child.kill = (signal) => { browser.child.signal = signal; return true; };
  let launches = 0;
  const { manager } = managerWithFakePage({
    launch: (file, options) => {
      launches += 1;
      return launchPage(file, { ...options, spawn: browser.spawn });
    },
  });
  const inFlight = manager.consumeTicket(manager.createTicket({ tokenId: 'token-2' }).ticket);
  const pending = manager.createTicket({ tokenId: 'token-3' }).ticket;
  const attaching = attached(manager);
  let finished = false;
  const stopped = manager.closeAll().then(() => { finished = true; });
  const stoppedAgain = manager.closeAll();
  await Promise.resolve();
  assert.equal(finished, false);
  assert.throws(() => manager.createTicket({ tokenId: 'token-4' }), { code: 'BROWSER_UNAVAILABLE' });
  assert.equal(manager.consumeTicket(pending), null);
  for (const ticket of [inFlight, { tokenId: 'token-4', file: '/fake/chrome' }]) {
    const client = new FakeClient();
    await manager.attachClient(ticket, client);
    assert.equal(client.json[0].code, 'BROWSER_UNAVAILABLE');
    assert.equal(client.closeCode, 1001);
  }
  assert.equal(launches, 1);
  browser.child.emit('exit');
  await Promise.all([stopped, stoppedAgain, attaching]);
  assert.equal(fs.existsSync(browser.child.profile), false);
});

for (const method of ['Target.createTarget', 'Target.attachToTarget', 'Target.setDiscoverTargets']) {
  test(`browser startup times out and cleans up when ${method} stalls`, async () => {
    const browser = fakeBrowser(method);
    const ready = launchPage('/fake/chrome', { spawn: browser.spawn, callTimeoutMs: 20 });
    await assert.rejects(ready, { code: 'BROWSER_START_FAILED', message: new RegExp(`${method} timed out`) });
    assert.equal(browser.child.signal, 'SIGKILL');
    await ready.closed;
    assert.equal(fs.existsSync(browser.child.profile), false);
  });
}

test('revoking a token immediately closes its browser and invalidates its tickets', async (t) => {
  const { manager, page } = managerWithFakePage();
  const client = await attached(manager);
  const pendingTicket = manager.createTicket({ tokenId: 'token-1' }).ticket;
  const terminalClosed = [];
  const app = express();
  app.use(createMetaRouter({
    browserManager: manager,
    terminalManager: { closeSession: (id) => terminalClosed.push(id) },
    bearerToken: () => 'device-token',
    revokeTokenById: (id) => id === 'token-1' && { id, token: 'device-token' },
  }));
  const server = await new Promise((resolve) => {
    const listening = app.listen(0, '127.0.0.1', () => resolve(listening));
  });
  t.after(async () => { server.close(); await manager.closeAll(); });
  const response = await fetch(`http://127.0.0.1:${server.address().port}/api/tokens/token-1/revoke`, { method: 'POST' });
  assert.equal(response.status, 200);
  assert.equal(page.closed, true);
  assert.equal(client.closeCode, 1000);
  assert.deepEqual(terminalClosed, ['token-1']);
  assert.equal(manager.consumeTicket(pendingTicket), null);
  assert.equal(manager.closeSession('token-1'), false);
});

test('the address bar accepts only loopback http(s) addresses', () => {
  assert.equal(loopbackUrl('3000'), 'http://localhost:3000/');
  assert.equal(loopbackUrl('3000/admin'), 'http://localhost:3000/admin');
  assert.equal(loopbackUrl('localhost:5173/admin?x=1'), 'http://localhost:5173/admin?x=1');
  assert.equal(loopbackUrl(' 127.0.0.1:8080 '), 'http://127.0.0.1:8080/');
  assert.equal(loopbackUrl('https://app.localhost'), 'https://app.localhost/');
  assert.equal(loopbackUrl('http://[::1]:3000'), 'http://[::1]:3000/');
  assert.equal(loopbackUrl('127.1:3000'), 'http://127.0.0.1:3000/');
  assert.equal(loopbackUrl('example.com'), null);
  assert.equal(loopbackUrl('http://localhost.example.com'), null);
  assert.equal(loopbackUrl('http://127.0.0.1.nip.io'), null);
  assert.equal(loopbackUrl('file:///etc/passwd'), null);
  assert.equal(loopbackUrl('javascript:alert(1)'), null);
  assert.equal(loopbackUrl(''), null);
});

test('RELAY_BROWSER must point at an existing file', () => {
  assert.equal(findBrowser({ RELAY_BROWSER: '/no/such/browser' }, 'linux'), null);
  assert.equal(findBrowser({ RELAY_BROWSER: process.execPath }, 'linux'), process.execPath);
});

test('a ticket is refused when the host has no browser', () => {
  const manager = createBrowserManager({ findBrowser: () => null });
  assert.throws(() => manager.createTicket({ tokenId: 'token-1' }), { code: 'BROWSER_UNAVAILABLE' });
  manager.closeAll();
});

test('tickets are single use and expire', () => {
  let clock = 1000;
  const { manager } = managerWithFakePage({ now: () => clock });
  const { ticket } = manager.createTicket({ tokenId: 'token-1' });
  assert.ok(manager.consumeTicket(ticket));
  assert.equal(manager.consumeTicket(ticket), null);
  const late = manager.createTicket({ tokenId: 'token-1' }).ticket;
  clock += 31 * 1000;
  assert.equal(manager.consumeTicket(late), null);
  manager.closeAll();
});

test('client messages become validated CDP input', async () => {
  const { manager, page, launched } = managerWithFakePage();
  const client = await attached(manager);
  assert.deepEqual(launched, ['/fake/chrome']);
  assert.deepEqual(client.json[0], { type: 'ready', url: 'about:blank' });
  assert.ok(lastCall(page, 'Page.startScreencast'));
  const say = (message) => client.emit('message', Buffer.from(JSON.stringify(message)), false);

  say({ type: 'navigate', url: '5173/admin' });
  assert.deepEqual(lastCall(page, 'Page.navigate'), { url: 'http://localhost:5173/admin' });
  say({ type: 'navigate', url: 'https://example.com' });
  assert.equal(client.json.at(-1).type, 'rejected');
  assert.equal(page.calls.filter(([name]) => name === 'Page.navigate').length, 1);

  say({ type: 'resize', width: 412, height: 800, scale: 3.5, mobile: true });
  assert.deepEqual(lastCall(page, 'Emulation.setDeviceMetricsOverride'), {
    width: 412,
    height: 800,
    deviceScaleFactor: 2,
    mobile: true,
  });
  assert.equal(lastCall(page, 'Emulation.setTouchEmulationEnabled').enabled, true);

  say({ type: 'touch', event: 'touchMove', points: [{ x: 10, y: 20, id: 1 }] });
  assert.deepEqual(lastCall(page, 'Input.dispatchTouchEvent'), {
    type: 'touchMove',
    touchPoints: [{ x: 10, y: 20, id: 1 }],
  });
  say({ type: 'touch', event: 'touchMove', points: [{ x: 'nope', y: 1 }] });
  say({ type: 'touch', event: 'evil', points: [] });
  assert.equal(page.calls.filter(([name]) => name === 'Input.dispatchTouchEvent').length, 1);

  say({ type: 'mouse', event: 'mousePressed', x: 5, y: 6, button: 'left', buttons: 1, clickCount: 1 });
  assert.equal(lastCall(page, 'Input.dispatchMouseEvent').button, 'left');
  say({ type: 'mouse', event: 'mouseWheel', x: 5, y: 6, deltaY: 120 });
  assert.equal(lastCall(page, 'Input.dispatchMouseEvent').deltaY, 120);

  say({ type: 'text', text: '中文' });
  assert.deepEqual(lastCall(page, 'Input.insertText'), { text: '中文' });
  say({ type: 'key', key: 'Enter' });
  assert.equal(lastCall(page, 'Input.dispatchKeyEvent').type, 'keyUp');
  say({ type: 'key', key: 'constructor' });
  assert.equal(page.calls.filter(([name]) => name === 'Input.dispatchKeyEvent').length, 2);

  say({ type: 'reload' });
  assert.ok(lastCall(page, 'Page.reload'));
  manager.closeAll();
});

test('frames go out as binary, are acked after sending, and replay on reattach', async () => {
  const { manager, page } = managerWithFakePage();
  const first = await attached(manager);
  page.events.emit('Page.screencastFrame', { data: Buffer.from('jpeg-1').toString('base64'), sessionId: 7 });
  assert.equal(first.frames[0].toString(), 'jpeg-1');
  assert.deepEqual(lastCall(page, 'Page.screencastFrameAck'), { sessionId: 7 });

  first.close(1000);
  page.events.emit('Page.screencastFrame', { data: Buffer.from('jpeg-2').toString('base64'), sessionId: 8 });
  // Nobody is watching, so Chrome is left waiting instead of rendering more.
  assert.equal(page.calls.filter(([name]) => name === 'Page.screencastFrameAck').length, 1);

  const second = await attached(manager);
  assert.equal(second.frames[0].toString(), 'jpeg-2');
  assert.deepEqual(lastCall(page, 'Page.screencastFrameAck'), { sessionId: 8 });
  manager.closeAll();
});

test('captures an early screencast frame emitted synchronously while answering Page.startScreencast', async () => {
  const { manager, page } = managerWithFakePage();
  const send = page.send;
  page.send = (method, params) => {
    const result = send(method, params);
    if (method === 'Page.startScreencast') {
      // Chrome can emit the first frame in the same stdio chunk as the startScreencast response.
      page.events.emit('Page.screencastFrame', {
        data: Buffer.from('early-frame').toString('base64'),
        sessionId: 1,
      });
    }
    return result;
  };
  const client = await attached(manager);
  assert.equal(client.frames.length > 0, true);
  assert.equal(client.frames[0].toString(), 'early-frame');
  assert.deepEqual(lastCall(page, 'Page.screencastFrameAck'), { sessionId: 1 });
  await manager.closeAll();
});

test('a tab the page opens is closed and its address handed to the app once', async () => {
  const { manager, page } = managerWithFakePage();
  const client = await attached(manager);
  const opens = () => client.json.filter((m) => m.type === 'open');
  const closes = () => page.calls.filter(([name]) => name === 'Target.closeTarget');

  // The streamed tab itself and a popup still on about:blank are left alone.
  page.events.emit('Target.targetCreated', { targetInfo: { targetId: 'main-target', type: 'page', url: 'https://x.test/' } });
  page.events.emit('Target.targetCreated', { targetInfo: { targetId: 'pop', type: 'page', url: 'about:blank' } });
  assert.equal(closes().length, 0);

  page.events.emit('Target.targetInfoChanged', { targetInfo: { targetId: 'pop', type: 'page', url: 'https://github.com/a' } });
  page.events.emit('Target.targetInfoChanged', { targetInfo: { targetId: 'pop', type: 'page', url: 'https://github.com/a' } });
  assert.deepEqual(opens(), [{ type: 'open', url: 'https://github.com/a' }]);
  assert.deepEqual(closes(), [['Target.closeTarget', { targetId: 'pop' }]]);

  // A non-web address is closed but never sent to the device.
  page.events.emit('Target.targetCreated', { targetInfo: { targetId: 'file', type: 'page', url: 'file:///etc/passwd' } });
  assert.equal(closes().length, 2);
  for (const url of ['http://localhost:3000/preview', 'http://127.0.0.1:3000/', 'http://[::1]:3000/']) {
    page.events.emit('Target.targetCreated', { targetInfo: { targetId: url, type: 'page', url } });
    assert.deepEqual(lastCall(page, 'Page.navigate'), { url });
  }
  assert.equal(opens().length, 1);
  manager.closeAll();
});

test('navigation, dialogs and a second device are reported to the viewer', async () => {
  const { manager, page } = managerWithFakePage();
  const first = await attached(manager);
  page.events.emit('Page.frameNavigated', { frame: { id: 'main', url: 'http://localhost:3000/' } });
  page.events.emit('Page.frameNavigated', { frame: { id: 'ad', parentId: 'main', url: 'http://ads/' } });
  page.events.emit('Page.navigatedWithinDocument', { frameId: 'main', url: 'http://localhost:3000/#x' });
  assert.deepEqual(
    first.json.filter((m) => m.type === 'url').map((m) => m.url),
    ['http://localhost:3000/', 'http://localhost:3000/#x'],
  );

  page.events.emit('Page.javascriptDialogOpening', { type: 'alert', message: 'saved' });
  assert.deepEqual(lastCall(page, 'Page.handleJavaScriptDialog'), { accept: true, promptText: '' });
  assert.deepEqual(first.json.at(-1), { type: 'dialog', dialogType: 'alert', message: 'saved' });

  const second = await attached(manager);
  assert.equal(first.json.at(-1).type, 'replaced');
  assert.equal(first.closeCode, 4001);
  assert.deepEqual(second.json[0], { type: 'ready', url: 'http://localhost:3000/#x' });
  manager.closeAll();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(page.closed, true);
});

test('the browser closes after the viewer has been gone for the idle timeout', async () => {
  const { manager, page } = managerWithFakePage({ idleTimeoutMs: 20 });
  const client = await attached(manager);
  client.close(1000);
  await new Promise((resolve) => setTimeout(resolve, 60));
  assert.equal(page.closed, true);
  manager.closeAll();
});

test('a browser that fails to start is reported and not reused', async () => {
  let attempts = 0;
  const manager = createBrowserManager({
    findBrowser: () => '/fake/chrome',
    launch: async () => {
      attempts += 1;
      throw Object.assign(new Error('Could not start the browser: boom'), {
        code: 'BROWSER_START_FAILED',
      });
    },
  });
  const client = await attached(manager);
  assert.equal(client.json[0].code, 'BROWSER_START_FAILED');
  assert.equal(client.closeCode, 1011);
  await attached(manager);
  assert.equal(attempts, 2);
  manager.closeAll();
});

let routeServer;
let routeBase;
let routeTicketInput;

before(async () => {
  const app = express();
  app.use(
    createBrowserRouter({
      bearerToken: () => 'device-token',
      tokenRecordForToken: () => ({ id: 'record-1', revoked: false }),
      browserManager: {
        createTicket(input) {
          routeTicketInput = input;
          return { ticket: 'short-ticket', expiresInMs: 30000 };
        },
      },
    }),
  );
  await new Promise((resolve) => {
    routeServer = app.listen(0, '127.0.0.1', resolve);
  });
  routeBase = `http://127.0.0.1:${routeServer.address().port}`;
});

after(() => routeServer && routeServer.close());

test('browser route scopes a ticket to the authenticated token record', async () => {
  const response = await fetch(`${routeBase}/api/browser/ticket`, { method: 'POST' });
  assert.equal(response.status, 200);
  assert.deepEqual(routeTicketInput, { tokenId: 'record-1' });
  assert.deepEqual(await response.json(), { ok: true, ticket: 'short-ticket', expiresInMs: 30000 });
});

const realBrowser = findBrowser();

test('a real headless browser streams a local page and takes touch and mouse input', {
  skip: !realBrowser && 'no Chrome, Chromium or Edge on this host',
  timeout: 180000,
}, async () => {
  // The slider and button write to the hash, which comes back as a `url` message.
  const html = `<!doctype html><meta name=viewport content="width=device-width">
    <body style="margin:0" onload="location.hash='ready'">
    <input id=s type=range min=0 max=100 value=0 style="position:absolute;left:20px;top:100px;width:360px;height:40px;margin:0;touch-action:none"
      oninput="location.hash='s'+this.value">
    <button style="position:absolute;left:20px;top:300px;width:200px;height:80px"
      onclick="location.hash='clicked'">x</button>`;
  const site = http.createServer((_req, res) => res.end(html));
  await new Promise((resolve) => site.listen(0, '127.0.0.1', resolve));
  let browserProcess;
  let browserProfile;
  const manager = createBrowserManager({
    // A cold browser start on a shared CI runner can exceed the 10 s default.
    launch: (file, options) => launchPage(file, {
      ...options,
      callTimeoutMs: 45000,
      spawn(file, args, spawnOptions) {
        browserProfile = args.find((arg) => arg.startsWith('--user-data-dir=')).slice('--user-data-dir='.length);
        browserProcess = spawn(file, args, spawnOptions);
        return browserProcess;
      },
    }),
  });
  try {
    const client = await attached(manager);
    const first = client.json.find((m) => m.type !== 'ping');
    assert.equal(first?.type, 'ready', JSON.stringify(client.json));
    const say = (message) => client.emit('message', Buffer.from(JSON.stringify(message)), false);
    const waitFor = async (predicate, what) => {
      for (let i = 0; i < 600; i += 1) {
        if (predicate()) return;
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      assert.fail(`timed out waiting for ${what}: ${JSON.stringify(client.json)}`);
    };
    const urls = () => client.json.filter((m) => m.type === 'url').map((m) => m.url);

    say({ type: 'resize', width: 400, height: 800, scale: 1, mobile: true });
    say({ type: 'navigate', url: String(site.address().port) });
    await waitFor(() => urls().some((url) => url.endsWith(`:${site.address().port}/`)), 'navigation');
    await waitFor(() => urls().some((url) => url.endsWith('#ready')), 'page load');
    await waitFor(() => client.frames.length > 0, 'a frame');
    assert.equal(client.frames.at(-1)[0], 0xff, 'frames are JPEG');

    say({ type: 'touch', event: 'touchStart', points: [{ x: 30, y: 120, id: 0 }] });
    for (let x = 60; x <= 300; x += 40) {
      say({ type: 'touch', event: 'touchMove', points: [{ x, y: 120, id: 0 }] });
      await new Promise((resolve) => setTimeout(resolve, 16));
    }
    say({ type: 'touch', event: 'touchEnd', points: [] });
    await waitFor(() => urls().some((url) => /#s([5-9]\d|100)$/.test(url)), 'the slider to move');

    say({ type: 'resize', width: 1280, height: 800, scale: 1, mobile: false });
    say({ type: 'mouse', event: 'mousePressed', x: 100, y: 340, button: 'left', buttons: 1, clickCount: 1 });
    say({ type: 'mouse', event: 'mouseReleased', x: 100, y: 340, button: 'left', buttons: 0, clickCount: 1 });
    await waitFor(() => urls().some((url) => url.endsWith('#clicked')), 'the click');
  } finally {
    await manager.closeAll();
    site.close();
  }
  assert.ok(browserProcess.exitCode !== null || browserProcess.signalCode !== null);
  assert.equal(fs.existsSync(browserProfile), false);
});

test('the terminal upgrade handler passes browser sockets on and still 404s unknown paths', async () => {
  const { createTerminalManager } = require('../lib/terminal-manager');
  const { manager } = managerWithFakePage();
  const terminal = createTerminalManager({ pty: null });
  const server = http.createServer();
  terminal.attachServer(server, manager.handleUpgrade);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `ws://127.0.0.1:${server.address().port}`;
  const open = (url) =>
    new Promise((resolve) => {
      const socket = new WebSocket(url);
      socket.onmessage = (event) => resolve({ socket, data: JSON.parse(event.data) });
      socket.onerror = () => resolve({ socket, failed: true });
    });
  try {
    const { ticket } = manager.createTicket({ tokenId: 'token-1' });
    const ok = await open(`${base}/api/browser/connect?ticket=${ticket}`);
    assert.deepEqual(ok.data, { type: 'ready', url: 'about:blank' });
    ok.socket.close();
    assert.equal((await open(`${base}/api/browser/connect?ticket=${ticket}`)).failed, true);
    assert.equal((await open(`${base}/api/elsewhere`)).failed, true);
  } finally {
    manager.closeAll();
    terminal.closeAll();
    server.close();
  }
});
