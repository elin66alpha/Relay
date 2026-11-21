'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const {
  handleSlug,
  authorOf,
  parseMentions,
  deltaSince,
  buildGroupPrompt,
} = require('../lib/group-turn');

const LABELS = {
  claude: 'Claude Code',
  codex: 'Codex',
  opencode: 'OpenCode',
};
const labelFor = (key) => LABELS[key] || key;

function human(content) {
  return { role: 'user', content, metadata: { author: 'human' } };
}

function agentMsg(agentKey, content) {
  return { role: 'assistant', agent: agentKey, content, metadata: { author: agentKey } };
}

test('authorOf prefers explicit metadata, then role/agent', () => {
  assert.equal(authorOf({ metadata: { author: 'codex' } }), 'codex');
  assert.equal(authorOf({ role: 'user' }), 'human');
  assert.equal(authorOf({ role: 'assistant', agent: 'claude' }), 'claude');
  assert.equal(authorOf(null), '');
});

test('parseMentions returns summoned members in order, de-duplicated', () => {
  const members = ['claude', 'codex', 'opencode'];
  assert.deepEqual(
    parseMentions('hey @codex and @claude, then @codex again', members, labelFor),
    ['codex', 'claude'],
  );
});

test('parseMentions only matches current members and ignores email-like tokens', () => {
  const members = ['claude', 'codex'];
  // @opencode is not a member; foo@codex is an email-like token (preceded by a word char).
  assert.deepEqual(parseMentions('ping @opencode please', members, labelFor), []);
  assert.deepEqual(parseMentions('mail foo@codex now', members, labelFor), []);
  assert.deepEqual(parseMentions('@claude go', members, labelFor), ['claude']);
});

test('parseMentions matches by label slug as well as agent key', () => {
  const members = ['claude', 'codex'];
  assert.deepEqual(parseMentions('@ClaudeCode look here', members, labelFor), ['claude']);
});

test('parseMentions resolves names in any script, with no space after them', () => {
  const members = ['claude', 'codex', '4e7eeaf61885:claude'];
  const labels = {
    claude: '架构师',
    codex: 'Claude大哥',
    '4e7eeaf61885:claude': 'Claude Code (工作站)',
  };
  const handles = { claude: 'claude', codex: 'codex', '4e7eeaf61885:claude': '工作站:claude' };
  const parse = (text) => parseMentions(text, members, (k) => labels[k], (k) => handles[k]);
  assert.deepEqual(parse('请@架构师看一下'), ['claude']);
  assert.deepEqual(parse('@codex看看'), ['codex']);
  assert.deepEqual(parse('@claude: review this'), ['claude']);
  // The longest name wins over a shorter one it starts with.
  assert.deepEqual(parse('@Claude大哥 help'), ['codex']);
  assert.deepEqual(parse('ask @工作站:claude'), ['4e7eeaf61885:claude']);
  // A stray symbol never matches a name that has no ASCII slug.
  assert.deepEqual(parse('ok @- done @_'), []);
  // A name still has to end the word it starts.
  assert.deepEqual(parse('@codexbot and @codex-like'), []);
  assert.equal(handleSlug('工作站 二号'), '工作站-二号');
});

test('parseMentions ignores broad @all / @everyone aliases', () => {
  const members = ['claude', 'codex', 'opencode'];
  assert.deepEqual(parseMentions('@all huddle up', members, labelFor), []);
  assert.deepEqual(parseMentions('@everyone huddle up', members, labelFor), []);
});

test('deltaSince returns everything for an agent that never spoke', () => {
  const messages = [human('hi'), agentMsg('claude', 'hello')];
  assert.deepEqual(deltaSince(messages, 'codex'), messages);
});

test('deltaSince skips a failed turn, whose prompt never reached the session', () => {
  const failed = {
    ...agentMsg('codex', 'Codex is not logged in on the backend host.'),
    metadata: { author: 'codex', errorCode: 'NOT_LOGGED_IN' },
  };
  const messages = [human('@codex the spec: build X'), failed, human('@codex try again')];
  assert.deepEqual(deltaSince(messages, 'codex'), messages);
});

test('deltaSince ignores replies from before the member session was reset', () => {
  const messages = [
    { ...human('@claude plan it'), createdAt: '2026-01-01T00:00:00.000Z' },
    { ...agentMsg('claude', 'the plan'), createdAt: '2026-01-01T00:00:01.000Z' },
    { ...human('@claude go on'), createdAt: '2026-01-01T00:00:05.000Z' },
  ];
  assert.deepEqual(deltaSince(messages, 'claude', '2026-01-01T00:00:03.000Z'), messages);
  assert.deepEqual(deltaSince(messages, 'claude', '2026-01-01T00:00:00.500Z'), messages.slice(2));
});

test('deltaSince returns only messages after the agent last spoke', () => {
  const messages = [
    human('start'),
    agentMsg('claude', 'first'),
    human('reply'),
    agentMsg('codex', 'mid'),
    human('again'),
  ];
  assert.deepEqual(deltaSince(messages, 'claude'), [
    messages[2],
    messages[3],
    messages[4],
  ]);
});

test('buildGroupPrompt labels each speaker and marks the agent turn', () => {
  const delta = [human('build the parser'), agentMsg('codex', 'I can start the lexer')];
  const prompt = buildGroupPrompt({ selfLabel: 'Claude Code', delta, labelFor });
  assert.match(prompt, /You are "Claude Code"/);
  assert.match(prompt, /Human: build the parser/);
  assert.match(prompt, /Codex: I can start the lexer/);
  assert.match(prompt, /It is now your turn, Claude Code\./);
});

test('buildGroupPrompt handles an empty delta', () => {
  const prompt = buildGroupPrompt({ selfLabel: 'Codex', delta: [], labelFor });
  assert.match(prompt, /\(no new messages\)/);
});

test('buildGroupPrompt injects the member persona when given', () => {
  const delta = [human('start')];
  const prompt = buildGroupPrompt({
    selfLabel: 'Codex',
    persona: 'Own the database schema',
    delta,
    labelFor,
  });
  assert.match(prompt, /Your role in this swarm: Own the database schema/);
  // No persona -> no role line.
  const plain = buildGroupPrompt({ selfLabel: 'Codex', delta, labelFor });
  assert.doesNotMatch(plain, /Your role in this swarm/);
});

test('buildGroupPrompt lists the members this one can summon', () => {
  const delta = [human('start')];
  const prompt = buildGroupPrompt({
    selfLabel: 'Claude Code',
    delta,
    labelFor,
    roster: [
      { key: 'codex', label: 'Codex' },
      { key: 'opencode', label: 'Schema owner' },
    ],
  });
  // The @key form is what parseMentions always resolves, so it is what the
  // agent is shown — a multi-word nickname alone would not parse.
  assert.match(
    prompt,
    /Other members of this swarm: Codex \(@codex\), Schema owner \(@opencode\)\./,
  );
  // Without a roster (agent-to-agent summoning off) the prompt promises nothing.
  const alone = buildGroupPrompt({ selfLabel: 'Claude Code', delta, labelFor });
  assert.doesNotMatch(alone, /Other members of this swarm/);
});

test('buildGroupPrompt bounds the prompt and notes omitted history', () => {
  const big = 'x'.repeat(2000);
  const delta = [];
  for (let i = 0; i < 50; i += 1) delta.push(human(`${i} ${big}`));
  const maxBytes = 8 * 1024;
  const prompt = buildGroupPrompt({ selfLabel: 'Codex', delta, labelFor, maxBytes });
  assert.ok(Buffer.byteLength(prompt, 'utf8') <= maxBytes);
  assert.match(prompt, /\[earlier messages omitted\]/);
  // The most recent message must survive the truncation.
  assert.match(prompt, /Human: 49 /);
});

test('handleSlug normalizes peer names and parseMentions resolves readable handles', () => {
  assert.equal(handleSlug('Peer B'), 'peer-b');
  assert.equal(handleSlug('My Mac Studio!'), 'my-mac-studio');
  const members = ['claude', '4e7eeaf61885:claude'];
  const labels = { claude: 'Claude Code (Desk)', '4e7eeaf61885:claude': 'Claude Code (Peer B)' };
  const handles = { claude: 'claude', '4e7eeaf61885:claude': 'peer-b:claude' };
  assert.deepEqual(
    parseMentions('ask @peer-b:claude and @claude', members, (k) => labels[k], (k) => handles[k]),
    ['4e7eeaf61885:claude', 'claude'],
  );
  assert.deepEqual(
    parseMentions('legacy @4e7eeaf61885:claude still works', members, (k) => labels[k], (k) => handles[k]),
    ['4e7eeaf61885:claude'],
  );
});

test('buildGroupPrompt shows readable handles, machine/workdir locations, and cross-machine note', () => {
  const prompt = buildGroupPrompt({
    selfLabel: 'Claude Code (Desk)',
    selfMachine: 'Desk',
    selfWorkdir: '/work/desk',
    delta: [human('check both repos')],
    labelFor,
    roster: [
      {
        key: '4e7eeaf61885:claude',
        handle: 'peer-b:claude',
        label: 'Claude Code (Peer B)',
        machine: 'Peer B',
        workdir: '/srv/peer',
      },
    ],
  });
  assert.match(prompt, /You are running on Desk in \/work\/desk\./);
  assert.match(prompt, /Claude Code \(Peer B\) \(@peer-b:claude\) \[on Peer B in \/srv\/peer\]/);
  assert.match(prompt, /cannot read or edit files on another machine/i);
});
