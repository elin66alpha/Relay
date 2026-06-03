'use strict';

// Single source of truth for the per-agent Model / Effort / Permission controls
// exposed in the chat composer's "+" drawer. Each selectable option carries the
// exact CLI argv tokens it maps to, so agents.js can splice them into a spawn
// without knowing agent-specific flag shapes.
//
// Capability-aware: agy (Antigravity) exposes no model/effort selection in its
// CLI, so those groups are empty for it and the client hides those entries.
//
// Defaults preserve the historical behavior exactly: no --model, no effort flag,
// and permission = bypass (the old hard-coded --dangerously-skip-permissions /
// --dangerously-bypass-approvals-and-sandbox).

const fs = require('fs');
const path = require('path');

// Curated model catalog. Alias entries (opus/sonnet/haiku, gpt-5-codex) always
// resolve to the latest model the installed CLI ships, so a `claude update` /
// `codex update` makes the newest model usable with no catalog change. Brand-new
// PINNED model ids can be added without a code change via models-extra.json
// (see mergeExtraModels) — { "claude": [{ "id": "...", "label": "..." }], ... }.
const BASE_MODELS = {
  claude: [
    { id: 'default', label: 'Default (account)', args: [] },
    { id: 'opus', label: 'Opus (latest)', args: ['--model', 'opus'] },
    { id: 'sonnet', label: 'Sonnet (latest)', args: ['--model', 'sonnet'] },
    { id: 'haiku', label: 'Haiku (latest)', args: ['--model', 'haiku'] },
  ],
  codex: [
    { id: 'default', label: 'Default', args: [] },
    { id: 'gpt-5-codex', label: 'gpt-5-codex (latest)', args: ['-m', 'gpt-5-codex'] },
    { id: 'gpt-5', label: 'gpt-5', args: ['-m', 'gpt-5'] },
  ],
  agy: [],
};

const EFFORTS = {
  // Claude Code has a native --effort flag (low|medium|high|xhigh|max).
  claude: [
    { id: 'default', label: 'Default', args: [] },
    { id: 'low', label: 'Low', args: ['--effort', 'low'] },
    { id: 'medium', label: 'Medium', args: ['--effort', 'medium'] },
    { id: 'high', label: 'High', args: ['--effort', 'high'] },
    { id: 'xhigh', label: 'Extra high', args: ['--effort', 'xhigh'] },
    { id: 'max', label: 'Max', args: ['--effort', 'max'] },
  ],
  // Codex exposes reasoning effort via a config override, not a flag.
  codex: [
    { id: 'default', label: 'Default', args: [] },
    { id: 'minimal', label: 'Minimal', args: ['-c', 'model_reasoning_effort=minimal'] },
    { id: 'low', label: 'Low', args: ['-c', 'model_reasoning_effort=low'] },
    { id: 'medium', label: 'Medium', args: ['-c', 'model_reasoning_effort=medium'] },
    { id: 'high', label: 'High', args: ['-c', 'model_reasoning_effort=high'] },
  ],
  agy: [],
};

// Permission tiers. The first entry of each agent is the default and reproduces
// the previous always-bypass behavior. For Codex, non-bypass tiers must pin
// approval_policy=never — `codex exec` is non-interactive, so any approval
// prompt would hang forever instead of being answered.
const PERMISSIONS = {
  claude: [
    {
      id: 'bypass',
      label: 'Bypass (full auto)',
      description: 'Skip all permission checks. Current default.',
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
    {
      id: 'default',
      label: 'Ask (default mode)',
      description: 'Standard prompting; tools needing approval may block non-interactively.',
      args: ['--permission-mode', 'default'],
    },
  ],
  codex: [
    {
      id: 'bypass',
      label: 'Bypass (full auto)',
      description: 'No sandbox, no approvals. Current default.',
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
      description: 'Auto-approve all tool requests. Current default.',
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

const DEFAULTS = { model: 'default', effort: 'default', permission: 'bypass' };

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
  const base = BASE_MODELS[agentKey] || [];
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
    defaults: DEFAULTS,
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
  const s = settings || {};
  const out = {};
  for (const group of ['model', 'effort', 'permission']) {
    const list = groups[group];
    if (!list.length) continue;
    const chosen = pick(list, s[group], DEFAULTS[group]);
    out[group] = chosen ? chosen.id : DEFAULTS[group];
  }
  return out;
}

// Build the extra argv tokens implied by a settings object, in a stable order
// (model, effort, permission). Returns [] for unknown agents.
function buildArgs(agentKey, settings) {
  const groups = groupsFor(agentKey);
  const s = settings || {};
  const args = [];
  for (const group of ['model', 'effort', 'permission']) {
    const list = groups[group];
    if (!list.length) continue;
    const chosen = pick(list, s[group], DEFAULTS[group]);
    if (chosen && Array.isArray(chosen.args)) args.push(...chosen.args);
  }
  return args;
}

module.exports = {
  DEFAULTS,
  CLI,
  describeAgent,
  normalizeSettings,
  buildArgs,
};
