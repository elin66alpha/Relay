'use strict';

// Pure helpers for the group-chat orchestrator (see docs/handbook.md, "Swarms").
// These turn the canonical group transcript into per-agent prompt material:
//
//   * who authored a transcript message (attribution),
//   * which agents a human message summons (@mention parsing),
//   * the delta a given agent has not seen since it last spoke ("plan B"),
//   * a speaker-labeled prompt for that delta, bounded to the prompt size cap.
//
// Keeping them pure (no I/O, no agent runners) makes the labeling — the part the
// design calls out as what keeps attribution and tone correct — directly testable.

const HUMAN_AUTHOR = 'human';

// A group prompt shares the ordinary chat byte budget. The default leaves
// headroom below the 100KB request cap.
const DEFAULT_MAX_PROMPT_BYTES = 96 * 1024;

function slug(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');
}

// Machine/peer slug for readable @mentions: lowercase, runs of anything but
// letters and digits (in any script, so 工作站 survives) -> '-'.
function handleSlug(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, '-')
    .replace(/^-+|-+$/g, '');
}

// The author of a transcript message: explicit metadata.author wins (that is how
// the orchestrator records it), otherwise fall back to role/agent so a message
// written before attribution metadata still resolves sensibly.
function authorOf(message) {
  const metadata = message && message.metadata;
  if (metadata && typeof metadata.author === 'string' && metadata.author) {
    return metadata.author;
  }
  if (message && message.role === 'user') return HUMAN_AUTHOR;
  return (message && message.agent) || '';
}

const WORD_CHAR = /[A-Za-z0-9_-]/;

// How much of `rest` the name `name` covers when `rest` starts with it. A name
// ending in an ASCII word character must also end the word there, so `@codex`
// does not match inside `@codexbot` or `@codex-like`, while `@codex:` and CJK
// text right after it (`@codex看看`) still do.
function prefixLength(rest, name) {
  if (!name || !rest.startsWith(name)) return 0;
  const endsInWord = WORD_CHAR.test(name.charAt(name.length - 1));
  return endsInWord && WORD_CHAR.test(rest.charAt(name.length)) ? 0 : name.length;
}

// Ordered, de-duplicated list of member agent keys summoned in this message.
// What follows each `@` matches a member by its agent key, its readable handle
// (`@<peer-slug>:<agent>`), the slug of its label/nickname (`@ClaudeCode`), or
// the label/nickname/handle itself in any script and with no space after it
// (`@架构师看一下`); the longest match wins. Only current members can be
// summoned; broad aliases such as `@all` are intentionally ignored.
function parseMentions(prompt, members, labelFor, handleFor) {
  const text = String(prompt || '');
  const names = (Array.isArray(members) ? members : []).map((member) => {
    const label = String((typeof labelFor === 'function' && labelFor(member)) || '')
      .trim()
      .toLowerCase();
    return {
      member,
      key: member.toLowerCase(),
      handle: String((typeof handleFor === 'function' && handleFor(member)) || '').toLowerCase(),
      label,
      // Only an ASCII label slugs faithfully (`@ClaudeCode`); others match as written.
      labelSlug: /^[\x20-\x7e]*$/.test(label) ? slug(label) : '',
    };
  });
  const order = [];
  const re = /(?:^|[^\w@])@/g;
  while (re.exec(text) !== null) {
    // Names are at most a few hundred characters, so look no further.
    const rest = text.slice(re.lastIndex, re.lastIndex + 256).toLowerCase();
    const token = (/^[a-z0-9:_-]+/.exec(rest) || [''])[0];
    let best = null;
    let bestLength = 0;
    for (const name of names) {
      const length = Math.max(
        token && name.labelSlug && name.labelSlug === slug(token) ? token.length : 0,
        prefixLength(rest, name.key),
        prefixLength(rest, name.handle),
        prefixLength(rest, name.label),
      );
      if (length > bestLength) {
        best = name.member;
        bestLength = length;
      }
    }
    if (best && !order.includes(best)) order.push(best);
  }
  return order;
}

// The transcript tail an agent has not yet seen: everything after its own last
// reply that its session holds. A failed turn's message never reached the
// session, and a session reset at `resetAt` holds nothing from before then, so
// neither counts; an agent with no such reply sees the whole transcript so far.
function deltaSince(messages, agentKey, resetAt = '') {
  const list = Array.isArray(messages) ? messages : [];
  let lastIndex = -1;
  for (let i = list.length - 1; i >= 0; i -= 1) {
    const message = list[i];
    if (authorOf(message) !== agentKey) continue;
    if (message.metadata && message.metadata.errorCode) continue;
    if (resetAt && String(message.createdAt || '') <= resetAt) break;
    lastIndex = i;
    break;
  }
  return list.slice(lastIndex + 1);
}

function speakerLabel(message, labelFor) {
  const author = authorOf(message);
  if (author === HUMAN_AUTHOR) return 'Human';
  if (typeof labelFor === 'function') return labelFor(author) || author;
  return author;
}

function lineFor(message, labelFor) {
  const content = typeof (message && message.content) === 'string'
    ? message.content.trim()
    : '';
  if (!content) return '';
  return `${speakerLabel(message, labelFor)}: ${content}`;
}

// Build the prompt handed to the agent taking the floor: a header that states it
// is in a group and it is now its turn, the `roster` of members it may summon
// (already excluding itself; empty when agent-to-agent summoning is off), an
// optional `persona` line carrying the user's per-member work instructions, then
// each delta message labeled with its speaker. Bounded to maxBytes by keeping the
// most recent messages and noting any omission, so a long silence cannot produce
// a prompt that exceeds the request budget.
function formatLocation(machine, workdir) {
  const m = typeof machine === 'string' ? machine.trim() : '';
  const w = typeof workdir === 'string' ? workdir.trim() : '';
  if (m && w) return `on ${m} in ${w}`;
  if (m) return `on ${m}`;
  if (w) return `in ${w}`;
  return '';
}

function buildGroupPrompt({
  selfLabel,
  selfMachine,
  selfWorkdir,
  persona,
  delta,
  labelFor,
  roster,
  maxBytes = DEFAULT_MAX_PROMPT_BYTES,
}) {
  const name = String(selfLabel || 'this agent');
  const role = typeof persona === 'string' ? persona.trim() : '';
  const selfLoc = formatLocation(selfMachine, selfWorkdir);
  const selfLocationLine = selfLoc ? `\n\nYou are running ${selfLoc}.` : '';
  // Summoning only happens if the agent knows it can, and knows the exact token
  // that resolves. Each entry is `Label (@handle)` (with machine/workdir when
  // known): the handle always parses, while a nickname only does when it is a
  // single word.
  const rosterEntries = (Array.isArray(roster) ? roster : []).filter(
    (member) => member && member.key,
  );
  const hasLocations = Boolean(selfLoc) || rosterEntries.some(
    (member) => member.machine || member.workdir,
  );
  const others = rosterEntries.map((member) => {
    const handle = member.handle || member.key;
    const loc = formatLocation(member.machine, member.workdir);
    return loc
      ? `${member.label || member.key} (@${handle}) [${loc}]`
      : `${member.label || member.key} (@${handle})`;
  });
  const remoteNote = hasLocations
    ? ' You cannot read or edit files on another machine; ask that machine\'s member instead.'
    : '';
  const rosterLine = others.length
    ? `\n\nOther members of this swarm: ${others.join(', ')}. ` +
      'Mentioning one of them by that @name hands them the floor once you ' +
      'finish, and they will see this exchange. Only do it when you actually ' +
      'need them; say nothing of the sort to end the exchange.' +
      remoteNote
    : '';
  const header =
    `You are "${name}" in a group chat with a human and possibly other AI agents. ` +
    'Each line below is prefixed with its speaker. Reply only as yourself, ' +
    'addressing the conversation; it is now your turn to respond.' +
    selfLocationLine +
    rosterLine +
    (role ? `\n\nYour role in this swarm: ${role}` : '');
  const footer = `(It is now your turn, ${name}.)`;
  const omitted = '[earlier messages omitted]';

  const lines = [];
  for (const message of Array.isArray(delta) ? delta : []) {
    const line = lineFor(message, labelFor);
    if (line) lines.push(line);
  }

  const overhead =
    Buffer.byteLength(header, 'utf8') +
    Buffer.byteLength(footer, 'utf8') +
    Buffer.byteLength(omitted, 'utf8') +
    16;
  const budget = Math.max(1024, maxBytes - overhead);

  const kept = [];
  let total = 0;
  let truncated = false;
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const size = Buffer.byteLength(lines[i], 'utf8') + 2;
    if (kept.length > 0 && total + size > budget) {
      truncated = true;
      break;
    }
    kept.unshift(lines[i]);
    total += size;
  }
  if (truncated) kept.unshift(omitted);

  const body = kept.length > 0 ? kept.join('\n\n') : '(no new messages)';
  let prompt = `${header}\n\n${body}\n\n${footer}`;
  // Defence in depth: a single oversized message can still blow the budget;
  // hard-cap the generated protocol payload before handing it to a runner.
  if (Buffer.byteLength(prompt, 'utf8') > maxBytes) {
    prompt = Buffer.from(prompt, 'utf8').subarray(0, maxBytes).toString('utf8');
  }
  return prompt;
}

module.exports = {
  HUMAN_AUTHOR,
  handleSlug,
  authorOf,
  parseMentions,
  deltaSince,
  buildGroupPrompt,
};
