'use strict';

// Single source of truth for the per-agent Model / Effort / Permission controls
// exposed in the chat composer's "+" drawer. Each selectable option carries the
// exact CLI argv tokens it maps to, so agents.js can splice them into a spawn
// without knowing agent-specific flag shapes.
//
// Capability-aware: each agent only exposes the controls supported by its CLI.
// Antigravity (`agy`) supports --model and permission flags, but no effort flag.
//
// Every group is an explicit, named choice — there is no opaque "default" entry,
// so the user always knows exactly which model, reasoning effort, and permission
// tier is in effect. A never-configured scope starts from AGENT_DEFAULTS below.

const fs = require('fs');
const path = require('path');

const { discoverModels } = require('./model-discovery');
const { configuredAgyModel } = require('./agy-paths');

// Static fallback model catalog. The live list normally comes from
// model-discovery (which reads what the installed CLI actually ships, newest
// first, including legacy and brand-new models). These entries are used only
// when discovery is unavailable or disabled (RELAY_MODEL_DISCOVERY=0). Newer or
// older pinned ids can be added without a code change via models-extra.json (see
// mergeExtraModels).
const BASE_MODELS = {
  // Static fallback only — normally replaced by live discovery. Ids match the
  // discovered scheme (full model id) so toggling discovery never churns a
  // stored selection.
  claude: [
    { id: 'claude-opus-4-8', label: 'Opus 4.8', args: ['--model', 'claude-opus-4-8'] },
    { id: 'claude-opus-4-7', label: 'Opus 4.7', args: ['--model', 'claude-opus-4-7'] },
    { id: 'claude-opus-4-6', label: 'Opus 4.6', args: ['--model', 'claude-opus-4-6'] },
    {
      id: 'claude-sonnet-4-6',
      label: 'Sonnet 4.6',
      args: ['--model', 'claude-sonnet-4-6'],
    },
    {
      id: 'claude-haiku-4-5',
      label: 'Haiku 4.5',
      args: ['--model', 'claude-haiku-4-5'],
    },
  ],
  codex: [
    {
      id: 'gpt-5.5',
      label: 'GPT-5.5 (recommended)',
      description: 'Strongest option for complex coding and agentic work.',
      args: ['-m', 'gpt-5.5'],
    },
    {
      id: 'gpt-5.4',
      label: 'GPT-5.4',
      description: 'Strong coding and reasoning for pinned GPT-5.4 workflows.',
      args: ['-m', 'gpt-5.4'],
    },
    {
      id: 'gpt-5.4-mini',
      label: 'GPT-5.4 Mini (fast)',
      description: 'Faster, lower-cost option for lighter coding tasks.',
      args: ['-m', 'gpt-5.4-mini'],
    },
  ],
  agy: [
    {
      id: 'gemini-3-5-flash-medium',
      label: 'Gemini 3.5 Flash (Medium)',
      args: ['--model', 'Gemini 3.5 Flash (Medium)'],
    },
    {
      id: 'gemini-3-5-flash-high',
      label: 'Gemini 3.5 Flash (High)',
      args: ['--model', 'Gemini 3.5 Flash (High)'],
    },
    {
      id: 'gemini-3-5-flash-low',
      label: 'Gemini 3.5 Flash (Low)',
      args: ['--model', 'Gemini 3.5 Flash (Low)'],
    },
    {
      id: 'gemini-3-1-pro-low',
      label: 'Gemini 3.1 Pro (Low)',
      args: ['--model', 'Gemini 3.1 Pro (Low)'],
    },
    {
      id: 'gemini-3-1-pro-high',
      label: 'Gemini 3.1 Pro (High)',
      args: ['--model', 'Gemini 3.1 Pro (High)'],
    },
    {
      id: 'claude-sonnet-4-6-thinking',
      label: 'Claude Sonnet 4.6 (Thinking)',
      args: ['--model', 'Claude Sonnet 4.6 (Thinking)'],
    },
    {
      id: 'claude-opus-4-6-thinking',
      label: 'Claude Opus 4.6 (Thinking)',
      args: ['--model', 'Claude Opus 4.6 (Thinking)'],
    },
    {
      id: 'gpt-oss-120b-medium',
      label: 'GPT-OSS 120B (Medium)',
      args: ['--model', 'GPT-OSS 120B (Medium)'],
    },
  ],
  // opencode models are `provider/model`; these free entries work without
  // credentials. Live discovery isn't wired for opencode, so this static list
  // (plus models-extra.json) is the catalog. Run `opencode models` for the full
  // set, or add paid ids via models-extra.json.
  opencode: [
    { id: 'opencode/big-pickle', label: 'Big Pickle (free)', args: ['-m', 'opencode/big-pickle'] },
    { id: 'opencode/deepseek-v4-flash-free', label: 'DeepSeek V4 Flash (free)', args: ['-m', 'opencode/deepseek-v4-flash-free'] },
    { id: 'opencode/north-mini-code-free', label: 'North Mini Code (free)', args: ['-m', 'opencode/north-mini-code-free'] },
    { id: 'opencode/nemotron-3-ultra-free', label: 'Nemotron 3 Ultra (free)', args: ['-m', 'opencode/nemotron-3-ultra-free'] },
    { id: 'opencode/mimo-v2.5-free', label: 'MiMo v2.5 (free)', args: ['-m', 'opencode/mimo-v2.5-free'] },
  ],
  // Hermes' model is `provider/model` and is normally set via `hermes setup` /
  // config.yaml. Left empty so the configured default is used; pin specific ids
  // via models-extra.json to expose a picker.
  hermes: [],
};

const EFFORTS = {
  // Claude Code has a native --effort flag (low|medium|high|xhigh|max).
  claude: [
    { id: 'low', label: 'Low', args: ['--effort', 'low'] },
    { id: 'medium', label: 'Medium', args: ['--effort', 'medium'] },
    { id: 'high', label: 'High', args: ['--effort', 'high'] },
    { id: 'xhigh', label: 'Extra high', args: ['--effort', 'xhigh'] },
    { id: 'max', label: 'Max', args: ['--effort', 'max'] },
  ],
  // Codex exposes reasoning effort via a config override, not a flag.
  codex: [
    { id: 'minimal', label: 'Minimal', args: ['-c', 'model_reasoning_effort=minimal'] },
    { id: 'low', label: 'Low', args: ['-c', 'model_reasoning_effort=low'] },
    { id: 'medium', label: 'Medium', args: ['-c', 'model_reasoning_effort=medium'] },
    { id: 'high', label: 'High', args: ['-c', 'model_reasoning_effort=high'] },
    { id: 'xhigh', label: 'Extra high', args: ['-c', 'model_reasoning_effort=xhigh'] },
  ],
  agy: [],
  // opencode exposes reasoning effort via `--variant`, but valid variants are
  // model-specific (an unsupported one errors), so it stays opt-in with no
  // default — selecting one adds `--variant <id>`.
  opencode: [
    { id: 'minimal', label: 'Minimal', args: ['--variant', 'minimal'] },
    { id: 'medium', label: 'Medium', args: ['--variant', 'medium'] },
    { id: 'high', label: 'High', args: ['--variant', 'high'] },
    { id: 'max', label: 'Max', args: ['--variant', 'max'] },
  ],
  // Hermes has no per-invocation reasoning-effort flag.
  hermes: [],
};

// Fast mode is deliberately limited to the two CLIs with a real speed tier.
// Both values are explicit so Relay overrides (rather than mutates or inherits)
// the host user's global CLI preference on every invocation.
const FAST_MODES = {
  claude: [
    { id: 'off', label: 'Off', args: ['--settings', '{"fastMode":false}'] },
    { id: 'on', label: 'On', args: ['--settings', '{"fastMode":true}'] },
  ],
  codex: [
    { id: 'off', label: 'Off', args: ['-c', 'service_tier="default"'] },
    { id: 'on', label: 'On', args: ['-c', 'service_tier="fast"'] },
  ],
};

// Permission tiers. The bypass tier is listed first but is no longer the
// default — AGENT_DEFAULTS below picks a safer "auto" tier per agent. For
// Codex, non-bypass tiers must pin approval_policy=never — `codex exec` is
// non-interactive, so any approval prompt would hang forever instead of being
// answered.
const PERMISSIONS = {
  claude: [
    {
      id: 'bypass',
      label: 'Bypass (full auto)',
      description: 'Skip all permission checks.',
      args: ['--dangerously-skip-permissions'],
    },
    {
      id: 'acceptEdits',
      label: 'Auto-accept edits',
      description: 'Auto-approve file edits; other tools may block in non-interactive mode.',
      args: ['--permission-mode', 'acceptEdits'],
    },
    {
      id: 'plan',
      label: 'Plan only (read-only)',
      description: 'Read and plan, but make no changes.',
      args: ['--permission-mode', 'plan'],
    },
  ],
  codex: [
    {
      id: 'bypass',
      label: 'Bypass (full auto)',
      description: 'No sandbox, no approvals.',
      args: ['--dangerously-bypass-approvals-and-sandbox'],
    },
    // Use the `-c sandbox_mode=` config override rather than `-s`: `codex exec
    // resume` accepts `-c` but not `-s`, so the config form works for both new
    // and resumed turns. approval_policy=never is mandatory — exec is
    // non-interactive, so any approval prompt would hang.
    {
      id: 'workspace-write',
      label: 'Workspace write',
      description: 'Edit inside the workspace; network/other paths blocked.',
      args: ['-c', 'sandbox_mode=workspace-write', '-c', 'approval_policy=never'],
    },
    {
      id: 'read-only',
      label: 'Read only',
      description: 'Inspect files but make no changes.',
      args: ['-c', 'sandbox_mode=read-only', '-c', 'approval_policy=never'],
    },
    {
      id: 'full-access',
      label: 'Full access',
      description: 'No sandbox restrictions, approvals auto-skipped.',
      args: ['-c', 'sandbox_mode=danger-full-access', '-c', 'approval_policy=never'],
    },
  ],
  agy: [
    {
      id: 'bypass',
      label: 'Bypass (full auto)',
      description: 'Auto-approve all tool requests.',
      args: ['--dangerously-skip-permissions'],
    },
    {
      id: 'sandbox',
      label: 'Sandbox',
      description: 'Run with terminal restrictions enabled.',
      args: ['--sandbox'],
    },
  ],
  // opencode `run` is non-interactive, so the default tier auto-approves (a
  // prompt would hang). "Ask" leaves approvals to opencode (may block edits).
  opencode: [
    {
      id: 'bypass',
      label: 'Bypass (full auto)',
      description: 'Auto-approve every tool, including edits and commands.',
      args: ['--dangerously-skip-permissions'],
    },
    {
      id: 'ask',
      label: 'Ask',
      description: 'Let opencode decide; some actions may be blocked.',
      args: [],
    },
  ],
  // Hermes' chat -q is non-interactive; --yolo bypasses approval prompts so the
  // run can't hang. "Cautious" omits it (Hermes may block dangerous commands).
  hermes: [
    {
      id: 'yolo',
      label: 'Auto-approve (yolo)',
      description: 'Bypass all approval prompts.',
      args: ['--yolo'],
    },
    {
      id: 'cautious',
      label: 'Cautious',
      description: 'Keep approvals; dangerous commands may be blocked.',
      args: [],
    },
  ],
};

// claude/codex/agy CLI invocation + how to query/update each binary.
const CLI = {
  claude: { bin: 'claude', versionArgs: ['--version'], updateArgs: ['update'] },
  codex: { bin: 'codex', versionArgs: ['--version'], updateArgs: ['update'] },
  agy: { bin: 'agy', versionArgs: ['--version'], updateArgs: ['update'] },
  // TODO(opencode/hermes): confirm version/update subcommands once installed.
  opencode: { bin: 'opencode', versionArgs: ['--version'], updateArgs: ['upgrade'] },
  hermes: { bin: 'hermes', versionArgs: ['--version'], updateArgs: ['update'] },
};

// The initial effort / permission for a never-configured scope. Every value is
// a real, user-visible option id (no opaque "default") so the effective setting
// is always knowable. The model default is derived from the live catalog (newest
// first) rather than pinned here, so it tracks the installed CLI. Permission
// starts on a safer "auto" tier instead of full bypass: claude auto-accepts
// edits, codex writes within the workspace (approvals disabled so exec never
// hangs), and agy runs sandboxed.
const AGENT_DEFAULTS = {
  claude: { effort: 'high', permission: 'acceptEdits', fast: 'off' },
  codex: { effort: 'medium', permission: 'workspace-write', fast: 'off' },
  agy: { permission: 'sandbox' },
  // Non-interactive defaults that can actually do work; effort stays unset
  // (model-specific) and opencode's model default comes from the catalog.
  opencode: { permission: 'bypass' },
  hermes: { permission: 'yolo' },
};

// Agents whose model group gets an automatic default (the newest catalog entry
// or the CLI's configured default when available).
const MODEL_DEFAULT_AGENTS = new Set(['claude', 'codex', 'agy', 'opencode']);

function modelDiscoveryDisabled() {
  return (
    process.env.RELAY_MODEL_DISCOVERY === '0' ||
    process.env.RELAY_MODEL_DISCOVERY === 'false'
  );
}

function configuredAgyModelId(models) {
  if (modelDiscoveryDisabled()) return null;
  const configured = configuredAgyModel();
  if (!configured) return null;
  const match = models.find((model) => model.label === configured);
  return match ? match.id : null;
}

function defaultsFor(agentKey) {
  return defaultsForModels(agentKey, modelsFor(agentKey));
}

const EXTRA_MODELS_FILE = path.join(__dirname, '..', 'models-extra.json');

// Merge user-supplied pinned models from models-extra.json on top of the base
// catalog. Entries are appended (deduped by id); a brand-new model becomes
// selectable by editing that file alone, no redeploy. Malformed files are
// ignored so a typo never breaks the options endpoint.
function mergeExtraModels(agentKey, base) {
  let extra;
  try {
    extra = JSON.parse(fs.readFileSync(EXTRA_MODELS_FILE, 'utf-8'));
  } catch (_err) {
    return base;
  }
  const list = extra && Array.isArray(extra[agentKey]) ? extra[agentKey] : null;
  if (!list) return base;
  const seen = new Set(base.map((m) => m.id));
  const merged = base.slice();
  for (const item of list) {
    if (!item || typeof item.id !== 'string' || seen.has(item.id)) continue;
    // The arg shape differs per agent; honor an explicit args array, else infer
    // the standard model flag for that agent.
    let args = Array.isArray(item.args) ? item.args : null;
    if (!args) {
      if (agentKey === 'claude') args = ['--model', item.id];
      else if (agentKey === 'codex' || agentKey === 'opencode' || agentKey === 'hermes') {
        args = ['-m', item.id];
      } else args = [];
    }
    seen.add(item.id);
    const model = {
      id: item.id,
      label: item.label || item.id,
      description:
        typeof item.description === 'string' ? item.description : undefined,
      args,
    };
    if (agentKey === 'codex' && Array.isArray(item.efforts)) {
      const effortIds = new Set();
      model.efforts = item.efforts
        .map((raw) => {
          const rawId = typeof raw === 'string' ? raw : raw && raw.id;
          const id = String(rawId || '').trim();
          if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/.test(id) || effortIds.has(id)) {
            return null;
          }
          effortIds.add(id);
          return {
            id,
            label:
              raw && typeof raw.label === 'string'
                ? raw.label
                : id === 'xhigh'
                  ? 'Extra high'
                  : id.charAt(0).toUpperCase() + id.slice(1),
            description:
              raw && typeof raw.description === 'string'
                ? raw.description
                : undefined,
            args: ['-c', `model_reasoning_effort=${id}`],
          };
        })
        .filter(Boolean);
      const requestedDefault = String(item.defaultEffort || '').trim();
      model.defaultEffort = effortIds.has(requestedDefault)
        ? requestedDefault
        : model.efforts[0] && model.efforts[0].id;
    }
    merged.push(model);
  }
  return merged;
}

function fallbackModelsFor(agentKey) {
  const models = BASE_MODELS[agentKey] || [];
  if (agentKey !== 'codex') return models;
  const supported = new Set(['low', 'medium', 'high', 'xhigh']);
  const efforts = EFFORTS.codex.filter((effort) => supported.has(effort.id));
  return models.map((model) => ({
    ...model,
    efforts,
    defaultEffort: 'medium',
  }));
}

function modelsFor(agentKey) {
  // Prefer the live list the installed CLI ships (so the picker tracks the
  // binary, including brand-new models); fall back to the static catalog when
  // discovery is unavailable. User pins from models-extra.json apply either way.
  const discovered = discoverModels(agentKey);
  const base =
    discovered && discovered.length ? discovered : fallbackModelsFor(agentKey);
  return mergeExtraModels(agentKey, base);
}

function effortOptionsFor(agentKey, model) {
  if (model && Array.isArray(model.efforts)) {
    return model.efforts;
  }
  return EFFORTS[agentKey] || [];
}

function effortDefaultFor(agentKey, model, efforts) {
  if (!efforts.length) return null;
  const requested =
    model && typeof model.defaultEffort === 'string'
      ? model.defaultEffort
      : (AGENT_DEFAULTS[agentKey] || {}).effort;
  return efforts.find((option) => option.id === requested) || null;
}

function defaultsForModels(agentKey, models) {
  const defaults = { ...(AGENT_DEFAULTS[agentKey] || {}) };
  let defaultModel = null;
  if (MODEL_DEFAULT_AGENTS.has(agentKey) && models.length) {
    const modelId =
      agentKey === 'agy'
        ? configuredAgyModelId(models) || models[0].id
        : models[0].id;
    defaultModel = models.find((model) => model.id === modelId) || models[0];
    defaults.model = defaultModel.id;
  }
  const efforts = effortOptionsFor(agentKey, defaultModel);
  const effort = effortDefaultFor(agentKey, defaultModel, efforts);
  if (effort) defaults.effort = effort.id;
  else delete defaults.effort;
  return defaults;
}

function groupsFor(agentKey, settings) {
  const models = modelsFor(agentKey);
  const defaults = defaultsForModels(agentKey, models);
  const selectedModel = pick(models, settings && settings.model, defaults.model);
  return {
    model: models,
    effort: effortOptionsFor(agentKey, selectedModel),
    permission: PERMISSIONS[agentKey] || [],
    fast: FAST_MODES[agentKey] || [],
    defaults,
    selectedModel,
  };
}

// Public-facing catalog for one agent: stripped of internal `args`, plus which
// groups the agent actually supports. Consumed by GET /api/agent-options.
function describeAgent(agentKey) {
  const groups = groupsFor(agentKey);
  const strip = (list) =>
    list.map(({ id, label, description }) => ({ id, label, description }));
  const effortByModel = {};
  const defaultEffortByModel = {};
  for (const model of groups.model) {
    const efforts = effortOptionsFor(agentKey, model);
    if (Array.isArray(model.efforts) || efforts.length) {
      effortByModel[model.id] = strip(efforts);
    }
    const effort = effortDefaultFor(agentKey, model, efforts);
    if (effort) defaultEffortByModel[model.id] = effort.id;
  }
  return {
    agent: agentKey,
    defaults: groups.defaults,
    supports: {
      model: groups.model.length > 0,
      effort:
        groups.effort.length > 0 ||
        groups.model.some(
          (model) => effortOptionsFor(agentKey, model).length > 0,
        ),
      permission: groups.permission.length > 0,
      fast: groups.fast.length > 0,
    },
    model: strip(groups.model),
    effort: strip(groups.effort),
    effortByModel,
    defaultEffortByModel,
    permission: strip(groups.permission),
    fast: strip(groups.fast),
  };
}

function pick(list, id, fallbackId) {
  return (
    list.find((o) => o.id === id) ||
    list.find((o) => o.id === fallbackId) ||
    null
  );
}

// Normalize an arbitrary settings object to valid ids for the agent, dropping
// selections the agent doesn't support.
function normalizeSettings(agentKey, settings) {
  const s = settings || {};
  const groups = groupsFor(agentKey, s);
  const out = {};
  const model = pick(groups.model, s.model, groups.defaults.model);
  if (model) out.model = model.id;
  const efforts = effortOptionsFor(agentKey, model);
  const defaultEffort = effortDefaultFor(agentKey, model, efforts);
  const effort = pick(efforts, s.effort, defaultEffort && defaultEffort.id);
  if (effort) out.effort = effort.id;
  const permission = pick(
    groups.permission,
    s.permission,
    groups.defaults.permission,
  );
  if (permission) out.permission = permission.id;
  const fast = pick(groups.fast, s.fast, groups.defaults.fast);
  if (fast) out.fast = fast.id;
  return out;
}

// Build the extra argv tokens implied by a settings object, in a stable order
// (model, effort, permission). Returns [] for unknown agents.
function buildArgs(agentKey, settings) {
  const s = settings || {};
  const groups = groupsFor(agentKey, s);
  const model = pick(groups.model, s.model, groups.defaults.model);
  const efforts = effortOptionsFor(agentKey, model);
  const defaultEffort = effortDefaultFor(agentKey, model, efforts);
  const effort = pick(efforts, s.effort, defaultEffort && defaultEffort.id);
  const permission = pick(
    groups.permission,
    s.permission,
    groups.defaults.permission,
  );
  const fast = pick(groups.fast, s.fast, groups.defaults.fast);
  const args = [];
  for (const chosen of [model, effort, permission, fast]) {
    if (chosen && Array.isArray(chosen.args)) args.push(...chosen.args);
  }
  return args;
}

module.exports = {
  defaultsFor,
  CLI,
  describeAgent,
  normalizeSettings,
  buildArgs,
};
