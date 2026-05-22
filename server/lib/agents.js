'use strict';

const { spawn } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { getWorkdir } = require('./workdir');

const TIMEOUT_MS = parseInt(
  process.env.AGENT_TIMEOUT_MS || String(60 * 60 * 1000),
  10,
);

// ---------- 持久会话：每个 session key 各保持一条连续会话，跨消息保留上下文 ----------
// HTTP 后端是单机单用户入口，但会话按 deviceId:agentKey 区分。clearSession 让 app 的
// “新会话/清空对话”能把后端上下文也一并重置，否则清完本地历史后端仍会 resume 旧会话。
const SESSION_FILE = path.join(__dirname, '..', 'agent-sessions.json');

class AgentCancelledError extends Error {
  constructor() {
    super('request cancelled');
    this.name = 'AgentCancelledError';
    this.code = 'AGENT_CANCELLED';
  }
}

function loadSessions() {
  try {
    return JSON.parse(fs.readFileSync(SESSION_FILE, 'utf-8'));
  } catch (_err) {
    return {};
  }
}

function saveSessions(sessions) {
  fs.writeFileSync(SESSION_FILE, JSON.stringify(sessions), { mode: 0o600 });
}

function getSession(sessionKey) {
  return loadSessions()[sessionKey] || null;
}

function setSession(sessionKey, value) {
  const sessions = loadSessions();
  sessions[sessionKey] = value;
  saveSessions(sessions);
}

function clearSession(sessionKey) {
  const sessions = loadSessions();
  if (!(sessionKey in sessions)) return false;
  delete sessions[sessionKey];
  saveSessions(sessions);
  return true;
}

function emit(onEvent, event) {
  if (typeof onEvent !== 'function' || !event) return;
  try {
    if (typeof event === 'string') {
      onEvent({ type: 'progress', line: event });
    } else {
      onEvent(event);
    }
  } catch (_err) {
    // Progress callbacks should not affect the running agent.
  }
}

function oneLine(value, max = 100) {
  const text = String(value).replace(/\s+/g, ' ').trim();
  return text.length > max ? `${text.slice(0, max - 1)}...` : text;
}

function fallback(stdout, stderr, code, label) {
  const merged = [String(stdout).trim(), String(stderr).trim()]
    .filter(Boolean)
    .join('\n');
  return merged || `(${label} exited with code ${code}, no output)`;
}

function makeDeltaEmitter(onEvent) {
  let streamed = '';
  return (value) => {
    const text = String(value || '');
    if (!text) return;

    let delta = text;
    if (streamed && text.startsWith(streamed)) {
      delta = text.slice(streamed.length);
    } else if (streamed && streamed.endsWith(text)) {
      delta = '';
    }

    if (!delta) return;
    streamed += delta;
    emit(onEvent, { type: 'delta', text: delta });
  };
}

function spawnStream({ cmd, args, cwd, label, onLine, finalize, signal }) {
  return new Promise((resolve, reject) => {
    if (signal && signal.aborted) {
      reject(new AgentCancelledError());
      return;
    }

    const proc = spawn(cmd, args, {
      cwd,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    let buffer = '';
    let finished = false;

    const cleanup = () => {
      clearTimeout(timer);
      if (signal) signal.removeEventListener('abort', cancel);
    };

    const cancel = () => {
      if (finished) return;
      finished = true;
      cleanup();
      proc.kill('SIGKILL');
      reject(new AgentCancelledError());
    };

    const timer = setTimeout(() => {
      if (finished) return;
      finished = true;
      cleanup();
      proc.kill('SIGKILL');
      resolve(
        `处理超时（超过 ${Math.round(
          TIMEOUT_MS / 60000,
        )} 分钟），已终止。请拆分任务或简化指令。`,
      );
    }, TIMEOUT_MS);

    if (signal) signal.addEventListener('abort', cancel, { once: true });

    proc.stdout.on('data', (chunk) => {
      const text = chunk.toString();
      stdout += text;
      if (!onLine) return;
      buffer += text;
      let index;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (line.trim()) {
          try {
            onLine(line);
          } catch (_err) {
            // Ignore malformed progress lines.
          }
        }
      }
    });

    proc.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });

    proc.on('error', (err) => {
      if (finished) return;
      finished = true;
      cleanup();
      resolve(`无法启动 ${label}: ${err.message}`);
    });

    proc.on('close', (code) => {
      if (finished) return;
      finished = true;
      cleanup();
      if (onLine && buffer.trim()) {
        try {
          onLine(buffer);
        } catch (_err) {
          // Ignore trailing malformed progress.
        }
      }
      try {
        resolve(finalize({ code, stdout, stderr }));
      } catch (err) {
        resolve(`${label} 输出解析失败: ${err.message}`);
      }
    });
  });
}

function toolBrief(name, input) {
  const data = input || {};
  let detail = '';
  if (name === 'Bash') detail = data.command || '';
  else if (
    name === 'Read' ||
    name === 'Edit' ||
    name === 'Write' ||
    name === 'NotebookEdit'
  ) {
    detail = data.file_path || '';
  } else if (name === 'Grep' || name === 'Glob') {
    detail = data.pattern || data.glob || '';
  } else if (name === 'Task') {
    detail = data.description || '';
  } else if (name === 'WebFetch' || name === 'WebSearch') {
    detail = data.url || data.query || '';
  } else {
    detail = Object.keys(data).slice(0, 2).join(', ');
  }
  return `${name}${detail ? `: ${oneLine(detail, 80)}` : ''}`;
}

function runClaude(prompt, onEvent, sessionKey, signal) {
  const cwd = getWorkdir();
  const prior = getSession(sessionKey);
  const resuming = !!(prior && prior.id);
  // resume 复用原会话 ID；新会话用我们生成的 UUID 作为 --session-id
  let sessionId = resuming ? prior.id : crypto.randomUUID();
  let finalText = '';
  let isError = false;
  const emitDelta = makeDeltaEmitter(onEvent);

  const args = [
    '--print',
    '--output-format',
    'stream-json',
    '--verbose',
    '--dangerously-skip-permissions',
  ];
  if (resuming) args.push('--resume', sessionId);
  else args.push('--session-id', sessionId);
  args.push(String(prompt));

  return spawnStream({
    cmd: 'claude',
    args,
    cwd,
    label: 'claude',
    signal,
    onLine: (line) => {
      let event;
      try {
        event = JSON.parse(line);
      } catch (_err) {
        return;
      }
      if (event.session_id) sessionId = event.session_id; // 以 CLI 实际会话 ID 为准
      if (
        event.type === 'assistant' &&
        event.message &&
        Array.isArray(event.message.content)
      ) {
        for (const block of event.message.content) {
          if (block.type === 'text' && block.text) {
            emitDelta(block.text);
            emit(onEvent, `Claude: ${oneLine(block.text)}`);
          } else if (block.type === 'tool_use') {
            emit(onEvent, `Tool: ${toolBrief(block.name, block.input)}`);
          }
        }
      } else if (event.type === 'result') {
        if (event.subtype && event.subtype !== 'success') isError = true;
        if (typeof event.result === 'string') finalText = event.result;
      }
    },
    finalize: ({ stderr }) => {
      const error = String(stderr).trim();
      if (finalText.trim()) {
        if (!isError) setSession(sessionKey, { id: sessionId });
        return `${isError ? 'Claude 返回错误:\n' : ''}${finalText.trim()}`;
      }
      // resume 失败（旧会话已被清理）：丢弃会话，标记重试
      if (
        resuming &&
        /no conversation|session.*(not found|does not exist)|no such session|could not find/i.test(
          error,
        )
      ) {
        clearSession(sessionKey);
        return { __retry: true };
      }
      return error || '(claude 无输出)';
    },
  }).then((result) => {
    if (result && result.__retry) {
      emit(onEvent, '旧会话已失效，开新会话重试...');
      return runClaude(prompt, onEvent, sessionKey, signal);
    }
    return result;
  });
}

function codexItemLabel(item) {
  const type = item.type || item.item_type;
  if (type === 'command_execution') {
    return `Command: ${oneLine(item.command || '', 80)}`;
  }
  if (type === 'file_change' || type === 'patch_apply') {
    return 'File change';
  }
  if (type === 'agent_message') {
    return `Codex: ${oneLine(item.text || '')}`;
  }
  if (type === 'reasoning') return null;
  if (type === 'mcp_tool_call') {
    return `MCP: ${oneLine(item.tool || item.name || '', 60)}`;
  }
  if (type === 'web_search') {
    return `Search: ${oneLine(item.query || '', 60)}`;
  }
  return null;
}

function runCodex(prompt, onEvent, sessionKey, signal) {
  const cwd = getWorkdir();
  const prior = getSession(sessionKey);
  const resuming = !!(prior && prior.id);
  const lastMsg = path.join(
    os.tmpdir(),
    `codex-last-${process.pid}-${Date.now()}.txt`,
  );

  const common = [
    '--json',
    '--dangerously-bypass-approvals-and-sandbox',
    '--skip-git-repo-check',
    '-o',
    lastMsg,
  ];
  // resume 子命令不支持 -C，靠 spawn 的 cwd 定位；新建则显式 -C
  const args = resuming
    ? ['exec', 'resume', ...common, prior.id, String(prompt)]
    : ['exec', ...common, '-C', cwd, String(prompt)];

  let threadId = resuming ? prior.id : null;
  const emitDelta = makeDeltaEmitter(onEvent);

  return spawnStream({
    cmd: 'codex',
    args,
    cwd,
    label: 'codex',
    signal,
    onLine: (line) => {
      let event;
      try {
        event = JSON.parse(line);
      } catch (_err) {
        return;
      }
      if (event.type === 'thread.started' && event.thread_id) {
        threadId = event.thread_id;
      }
      if (
        event.type &&
        String(event.type).includes('delta') &&
        typeof event.text === 'string'
      ) {
        emitDelta(event.text);
      }
      if (event.type !== 'item.completed' || !event.item) return;
      if (event.item.type === 'agent_message' && event.item.text) {
        emitDelta(event.item.text);
      }
      const label = codexItemLabel(event.item);
      if (label) emit(onEvent, label);
    },
    finalize: ({ code, stdout, stderr }) => {
      let text = '';
      try {
        text = fs.readFileSync(lastMsg, 'utf-8').trim();
        fs.unlinkSync(lastMsg);
      } catch (_err) {
        // Fall back to process output.
      }
      const error = String(stderr).trim();
      if (
        !text &&
        resuming &&
        /no.*session|session.*not found|unknown session|no recorded|not found/i.test(
          error,
        )
      ) {
        clearSession(sessionKey);
        return { __retry: true };
      }
      if (text) {
        if (threadId) setSession(sessionKey, { id: threadId });
        return text;
      }
      return fallback(stdout, stderr, code, 'codex');
    },
  }).then((result) => {
    if (result && result.__retry) {
      emit(onEvent, '旧会话已失效，开新会话重试...');
      return runCodex(prompt, onEvent, sessionKey, signal);
    }
    return result;
  });
}

// agy 无法指定会话 ID，但每个 cwd 的最近会话 ID 记在 last_conversations.json，
// 跑完读出来存起来，下次用 --conversation <id> 续接。
const AGY_LAST_CONV = path.join(
  os.homedir(),
  '.gemini',
  'antigravity-cli',
  'cache',
  'last_conversations.json',
);

function runAgy(prompt, onEvent, sessionKey, signal) {
  const cwd = getWorkdir();
  const prior = getSession(sessionKey);
  emit(onEvent, 'Antigravity 处理中...');
  const args = [
    '--print',
    String(prompt),
    '--dangerously-skip-permissions',
    '--add-dir',
    cwd,
  ];
  if (prior && prior.id) args.push('--conversation', prior.id);
  return spawnStream({
    cmd: 'agy',
    args,
    cwd,
    label: 'antigravity',
    onLine: null,
    signal,
    finalize: ({ code, stdout, stderr }) => {
      const text = String(stdout).trim();
      // 捕获本次会话 ID（按 cwd 记录），存给下次续接
      let convId = null;
      try {
        const map = JSON.parse(fs.readFileSync(AGY_LAST_CONV, 'utf-8'));
        if (map[cwd]) {
          convId = map[cwd];
          setSession(sessionKey, { id: convId });
        }
      } catch (_err) {
        // 读不到就下次重新建会话
      }

      // agy --print 续接时会把整段会话（含历次回复）一起打到 stdout，导致每次回复
      // 黏连之前所有回复。改为从本次会话的 transcript 里取最后一条 MODEL 的
      // PLANNER_RESPONSE，只返回这一轮的最终回答。
      if (convId) {
        try {
          const logDir = path.join(
            os.homedir(),
            '.gemini',
            'antigravity-cli',
            'brain',
            convId,
            '.system_generated',
            'logs',
          );
          const fullPath = path.join(logDir, 'transcript_full.jsonl');
          const normalPath = path.join(logDir, 'transcript.jsonl');
          const targetPath = fs.existsSync(fullPath) ? fullPath : normalPath;
          if (fs.existsSync(targetPath)) {
            const lines = fs
              .readFileSync(targetPath, 'utf-8')
              .trim()
              .split('\n');
            for (let i = lines.length - 1; i >= 0; i--) {
              if (!lines[i].trim()) continue;
              try {
                const obj = JSON.parse(lines[i]);
                if (
                  obj.source === 'MODEL' &&
                  obj.type === 'PLANNER_RESPONSE' &&
                  obj.content
                ) {
                  return obj.content.trim();
                }
              } catch (_err) {
                // 跳过无法解析的行
              }
            }
          }
        } catch (_err) {
          // transcript 解析失败则回退到 stdout
        }
      }

      return text || fallback(stdout, stderr, code, 'agy');
    },
  });
}

const AGENTS = {
  claude: {
    key: 'claude',
    label: 'Claude Code',
    description: 'Anthropic Claude Code CLI',
    emoji: 'C',
    run: runClaude,
  },
  codex: {
    key: 'codex',
    label: 'Codex',
    description: 'OpenAI Codex CLI',
    emoji: 'X',
    run: runCodex,
  },
  agy: {
    key: 'agy',
    label: 'Antigravity',
    description: 'Antigravity CLI',
    emoji: 'A',
    run: runAgy,
  },
};

const DEFAULT_AGENT = 'claude';

function listAgents() {
  return Object.values(AGENTS).map(({ key, label, description }) => ({
    key,
    label,
    description,
  }));
}

function getAgent(key) {
  return AGENTS[key] || null;
}

async function runAgent(agentKey, prompt, onEvent, options = {}) {
  const agent = getAgent(agentKey);
  if (!agent) {
    throw new Error(`Unknown agent: ${agentKey}`);
  }
  const sessionKey = options.sessionKey || agent.key;
  return agent.run(prompt, onEvent, sessionKey, options.signal);
}

module.exports = {
  AGENTS,
  AgentCancelledError,
  DEFAULT_AGENT,
  TIMEOUT_MS,
  listAgents,
  getAgent,
  runAgent,
  getSession,
  clearSession,
};
