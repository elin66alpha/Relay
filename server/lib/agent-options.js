'use strict';

// Single source of truth for the per-agent Model / Effort / Permission controls
// exposed in the chat composer's "+" drawer. Each selectable option carries the
// exact CLI argv tokens it maps to, so agents.js can splice them into a spawn
// without knowing agent-specific flag shapes.
//
// Capability-aware: agy (Antigravity) exposes no model/effort selection in its
// CLI, so those groups are empty for it and the client hides those entries.
//
// Every group is an explicit, named choice — there is no opaque "default" entry,
// so the user always knows exactly which model, reasoning effort, and permission
// tier is in effect. A never-configured scope starts from AGENT_DEFAULTS below.

const fs = require('fs');
const path = require('path');

const { discoverModels } = require('./model-discovery');

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
  agy: [],
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
  ],
  agy: [],
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
};

// claude/codex/agy CLI invocation + how to query/update each binary.
const CLI = {
  claude: { bin: 'claude', versionArgs: ['--version'], updateArgs: ['update'] },
  codex: { bin: 'codex', versionArgs: ['--version'], updateArgs: ['update'] },
  agy: { bin: 'agy', versionArgs: ['--version'], updateArgs: ['update'] },
};

// The initial effort / permission for a never-configured scope. Every value is
// a real, user-visible option id (no opaque "default") so the effective setting
// is always knowable. The model default is derived from the live catalog (newest
// first) rather than pinned here, so it tracks the installed CLI. Permission
// starts on a safer "auto" tier instead of full bypass: claude auto-accepts
// edits, codex writes within the workspace (approvals disabled so exec never
// hangs), and agy runs sandboxed.
const AGENT_DEFAULTS = {
  claude: { effort: 'high', permission: 'acceptEdits' },
  codex: { effort: 'medium', permission: 'workspace-write' },
  agy: { permission: 'sandbox' },
};

// Agents whose model group gets an automatic default (the newest catalog entry).
// agy is excluded: its discovered ids use an unverified --model arg, so leaving
// it unset keeps the default run on agy's own built-in model; selection is
// opt-in.
const MODEL_DEFAULT_AGENTS = new Set(['claude', 'codex']);

function defaultsFor(agentKey) {
  const defaults = { ...(AGENT_DEFAULTS[agentKey] || {}) };
  if (MODEL_DEFAULT_AGENTS.has(agentKey)) {
    const models = modelsFor(agentKey);
    if (models.length) defaults.model = models[0].id;
  }
  return defaults;
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
      else if (agentKey === 'codex') args = ['-m', item.id];
      else args = [];
    }
    seen.add(item.id);
    merged.push({ id: item.id, label: item.label || item.id, args });
  }
  return merged;
}

function modelsFor(agentKey) {
  // Prefer the live list the installed CLI ships (so the picker tracks the
  // binary, including brand-new models); fall back to the static catalog when
  // discovery is unavailable. User pins from models-extra.json apply either way.
  const discovered = discoverModels(agentKey);
  const base =
    discovered && discovered.length ? discovered : BASE_MODELS[agentKey] || [];
  return mergeExtraModels(agentKey, base);
}

function groupsFor(agentKey) {
  return {
    model: modelsFor(agentKey),
    effort: EFFORTS[agentKey] || [],
    permission: PERMISSIONS[agentKey] || [],
  };
}

// Public-facing catalog for one agent: stripped of internal `args`, plus which
// groups the agent actually supports. Consumed by GET /api/agent-options.
function describeAgent(agentKey) {
  const groups = groupsFor(agentKey);
  const strip = (list) =>
    list.map(({ id, label, description }) => ({ id, label, description }));
  return {
    agent: agentKey,
    defaults: defaultsFor(agentKey),
    supports: {
      model: groups.model.length > 0,
      effort: groups.effort.length > 0,
      permission: groups.permission.length > 0,
    },
    model: strip(groups.model),
    effort: strip(groups.effort),
    permission: strip(groups.permission),
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
// selections the agent doesn't support (e.g. model/effort on agy).
function normalizeSettings(agentKey, settings) {
  const groups = groupsFor(agentKey);
  const defaults = defaultsFor(agentKey);
  const s = settings || {};
  const out = {};
  for (const group of ['model', 'effort', 'permission']) {
    const list = groups[group];
    if (!list.length) continue;
    const chosen = pick(list, s[group], defaults[group]);
    out[group] = chosen ? chosen.id : defaults[group];
  }
  return out;
}

// Build the extra argv tokens implied by a settings object, in a stable order
// (model, effort, permission). Returns [] for unknown agents.
function buildArgs(agentKey, settings) {
  const groups = groupsFor(agentKey);
  const defaults = defaultsFor(agentKey);
  const s = settings || {};
  const args = [];
  for (const group of ['model', 'effort', 'permission']) {
    const list = groups[group];
    if (!list.length) continue;
    const chosen = pick(list, s[group], defaults[group]);
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
