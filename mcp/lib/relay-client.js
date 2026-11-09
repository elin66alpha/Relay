'use strict';

function relayError(status, body) {
  const message = (body && body.error) || `Relay request failed with HTTP ${status}`;
  const err = new Error(message);
  err.code = (body && body.code) || `HTTP_${status}`;
  err.status = status;
  return err;
}

// Calls the Relay HTTP API as one device: the bearer token from the credential,
// a stable device id, and the work directory this MCP process has selected.
function createRelayClient({ baseUrl, token, deviceId, deviceName, getWorkdir }) {
  function headers(extra = {}, workdir) {
    const out = {
      Authorization: `Bearer ${token}`,
      'x-device-id': deviceId,
      'x-device-name': deviceName,
      ...extra,
    };
    const dir = workdir || getWorkdir();
    if (dir) out['x-workdir'] = dir;
    return out;
  }

  function urlFor(path, query) {
    const url = new URL(`${baseUrl}${path}`);
    for (const [key, value] of Object.entries(query || {})) {
      if (value !== undefined && value !== null && value !== '') url.searchParams.set(key, String(value));
    }
    return url;
  }

  async function fetchOk(path, { method = 'GET', query, body, raw, workdir, accept, signal } = {}) {
    const init = { method, headers: headers(accept ? { Accept: accept } : {}, workdir), signal };
    if (raw !== undefined) {
      init.body = raw;
      init.headers['Content-Type'] = 'application/octet-stream';
    } else if (body !== undefined) {
      init.body = JSON.stringify(body);
      init.headers['Content-Type'] = 'application/json';
    }
    const res = await fetch(urlFor(path, query), init);
    if (!res.ok) {
      const text = await res.text();
      let parsed = null;
      try {
        parsed = JSON.parse(text);
      } catch (_err) {
        // Not JSON (a proxy page); the status alone explains it.
      }
      throw relayError(res.status, parsed);
    }
    return res;
  }

  async function json(path, options) {
    const res = await fetchOk(path, options);
    return res.json();
  }

  // POST and read the SSE reply until a terminal event or waitMs, whichever is
  // first. Disconnecting does not cancel the turn: the backend keeps running it
  // and records the result in history.
  async function stream(path, body, { waitMs, terminal, workdir, onEvent }) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), waitMs);
    let res;
    try {
      res = await fetchOk(path, {
        method: 'POST',
        body,
        workdir,
        accept: 'text/event-stream',
        signal: controller.signal,
      });
    } catch (err) {
      clearTimeout(timer);
      if (err.name === 'AbortError') return { done: false };
      throw err;
    }
    if (!String(res.headers.get('content-type') || '').includes('text/event-stream')) {
      clearTimeout(timer);
      return { done: true, type: 'json', payload: await res.json() };
    }
    const decoder = new TextDecoder();
    let buffer = '';
    let found = null;
    try {
      for await (const chunk of res.body) {
        buffer += decoder.decode(chunk, { stream: true });
        let index;
        while (!found && (index = buffer.indexOf('\n\n')) >= 0) {
          const event = parseEvent(buffer.slice(0, index));
          buffer = buffer.slice(index + 2);
          if (!event) continue;
          if (onEvent) onEvent(event);
          if (terminal.includes(event.type)) found = { done: true, ...event };
        }
        if (found) break;
      }
    } catch (err) {
      if (err.name !== 'AbortError') throw err;
    } finally {
      clearTimeout(timer);
      controller.abort();
    }
    return found || { done: false };
  }

  async function bytes(path, options) {
    const res = await fetchOk(path, options);
    return {
      contentType: String(res.headers.get('content-type') || ''),
      buffer: Buffer.from(await res.arrayBuffer()),
    };
  }

  return { json, stream, bytes, baseUrl, token };
}

function parseEvent(block) {
  let type = 'message';
  const data = [];
  for (const line of block.split('\n')) {
    if (line.startsWith('event:')) type = line.slice(6).trim();
    else if (line.startsWith('data:')) data.push(line.slice(5).trimStart());
  }
  if (!data.length) return null;
  try {
    return { type, payload: JSON.parse(data.join('\n')) };
  } catch (_err) {
    return null;
  }
}

module.exports = { createRelayClient, parseEvent };
