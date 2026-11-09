'use strict';

// Newest first; an unknown requested version is answered with the newest.
const PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

function resultText(value) {
  return typeof value === 'string' ? value : JSON.stringify(value, null, 2);
}

// One JSON-RPC message in, one response (or null for a notification) out.
function createMcpHandler({ name, version, instructions, tools }) {
  const byName = new Map(tools.map((tool) => [tool.name, tool]));

  async function dispatch(method, params) {
    if (method === 'initialize') {
      const requested = params && params.protocolVersion;
      return {
        protocolVersion: PROTOCOL_VERSIONS.includes(requested) ? requested : PROTOCOL_VERSIONS[0],
        capabilities: { tools: {} },
        serverInfo: { name, version },
        instructions,
      };
    }
    if (method === 'ping') return {};
    if (method === 'tools/list') {
      return {
        tools: tools.map((tool) => ({
          name: tool.name,
          description: tool.description,
          inputSchema: tool.inputSchema,
        })),
      };
    }
    if (method === 'tools/call') {
      const tool = byName.get(params && params.name);
      if (!tool) {
        const err = new Error(`unknown tool: ${params && params.name}`);
        err.rpcCode = -32602;
        throw err;
      }
      try {
        const value = await tool.handler((params && params.arguments) || {});
        return { content: [{ type: 'text', text: resultText(value) }] };
      } catch (err) {
        // Tool failures go back to the model as text it can act on.
        const detail = err.code ? ` (${err.code})` : '';
        return { content: [{ type: 'text', text: `${err.message}${detail}` }], isError: true };
      }
    }
    const err = new Error(`method not found: ${method}`);
    err.rpcCode = -32601;
    throw err;
  }

  return async function handle(message) {
    if (!message || typeof message !== 'object' || Array.isArray(message)) {
      return { jsonrpc: '2.0', id: null, error: { code: -32600, message: 'invalid request' } };
    }
    const isNotification = message.id === undefined || message.id === null;
    try {
      const result = await dispatch(message.method, message.params);
      return isNotification ? null : { jsonrpc: '2.0', id: message.id, result };
    } catch (err) {
      if (isNotification) return null;
      return {
        jsonrpc: '2.0',
        id: message.id,
        error: { code: err.rpcCode || -32603, message: err.message },
      };
    }
  };
}

module.exports = { createMcpHandler, PROTOCOL_VERSIONS };
