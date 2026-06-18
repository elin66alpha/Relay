# Group Chat (Swarm)

Design notes for the multi-agent group chat feature: one chat box, one human,
several agents, with clear attribution of who spoke and who summoned whom.

> **Naming.** The feature is surfaced to users as **"Swarm" (蜂群)**. The backend
> code, HTTP routes, and storage keep the original `group` terminology, so this
> document still says "group" when describing internals; "swarm" and "group"
> refer to the same thing.

## Decisions

These three choices are fixed for the first version:

1. **Summoning is manual (`@mention`).** Only the human summons an agent, by
   addressing it. Agents do not summon each other yet (agent-initiated summon
   chains are a later, guarded extension).
2. **Context sharing is per-agent resume + delta injection** ("plan B"). Each
   agent keeps its own resumable CLI session; between its turns the orchestrator
   injects only what happened in the group since it last spoke. The full group
   transcript is never re-sent on every turn.
3. **Turns are serialized.** A group has one floor; exactly one agent speaks at a
   time, through a turn queue. No parallel speakers.

## Core Model: Group Chat Is Orchestrated, Not Shared Memory

Each CLI agent keeps its **own private conversation memory** (`claude --resume`,
codex resume, agy's `last_conversations.json`, etc.). These memories are not
shared and cannot see each other. A group chat is therefore an orchestration on
top of independent per-agent sessions, not a shared brain:

- The backend stores **one canonical group transcript**.
- When it is agent X's turn, the orchestrator feeds X what it needs to know, X
  replies, and the reply is appended to the group transcript with attribution.
- From each CLI's point of view it is talking to a single user who relays a
  multi-party conversation. "Who summoned whom" is metadata the orchestrator
  records; it is not a native capability of the agents.

This means the feature is mostly **an orchestration layer + a new transcript
schema + a router**. The existing agent runners (`server/lib/agents.js`) are
reused unchanged.

## Scope And Data Model

A group is a new scope layer that sits above the existing per-agent scopes. Each
group pins its own **work tree** (`workdir`) — chosen when the swarm is created —
that all members collaborate in. The group is *listed* under the workspace it was
created in (the ambient `X-Workdir`), so one workspace can hold several swarms,
each operating on a different work tree (e.g. different git worktrees of a repo).
The work tree, not the workspace, is the basis of every runtime scope key below.

- **Group scope key**: `` `${workdir}\0group:${groupId}` `` (where `workdir` is
  the swarm's work tree), alongside the existing single-agent scope keys
  (`` `${workdir}\0${agentKey}` `` and `` `${workdir}\0${agent}\0${sessionId}` ``).
- **Members**: the ordered set of agent keys in the group, plus the human. Each
  member maps to its own underlying per-agent CLI session (in the swarm's work
  tree) so it keeps private memory.
- **Per-member config** (`memberConfigs`): each member's model / effort /
  permission is chosen when the swarm is created and stored **in the group
  itself**, independent of that agent's solo-chat selection. At run time a
  `getSettings` dependency override feeds these (normalized via
  `agent-options.js`) to `runAgentTurn`, so a swarm never reads or writes the
  per-`workdir+agent` `agent-settings.json` store.
- **Group transcript message** fields:
  - `author`: `human` or an `agentKey`.
  - `summonedBy`: who triggered this turn — `human` for the first version (later:
    an `agentKey` for summon chains, or a facilitator policy).
  - `timestamp`, plus segment metadata so multi-message turns render as
    collapsible blocks like single-agent turns already do.

Persist group state with `server/lib/json-store.js` (in-memory cache + atomic
0o600 writes), consistent with other backend state files.

## Turn Lifecycle

A single round, from a human message to the group becoming idle again:

1. **Human posts a message.** If it `@mentions` one or more agents, those agents
   are enqueued in mention order. A message with no mention does not start any
   agent turn (it is recorded and waits for the human to summon someone).
2. **Floor acquisition.** The orchestrator serializes group turns through the
   existing per-scope tail-promise mechanism (`scopeChains` in `server.js`), so a
   group behaves like a single serialized stream: one speaker at a time.
3. **Context assembly (plan B).** For the agent taking the floor, build a prompt
   containing only the **delta** since that agent last spoke — the new group
   messages, each clearly labeled with its speaker (human or other agent's name)
   and a marker that it is now this agent's turn. The agent's own resumable
   session supplies everything it already knew.
4. **Run + stream.** Spawn through the normal `runAgent(..., { workdir, settings
   })` path; stream `segment` events over SSE. Group SSE events carry the
   `groupId` (in addition to `scopeWorkdir`) so only clients viewing that group
   receive them.
5. **Append + attribute.** The reply is written to the group transcript with
   `author = agentKey` and `summonedBy = human`.
6. **Next in queue.** If more agents were mentioned, the next one takes the
   floor. When the queue drains, the group returns to **idle / waiting for
   human**. This idle state is the termination condition.

The human can post again at any time; new mentions append to the queue.

## Speaker Labeling In Prompts

Because agents do not natively know they are in a group, the injected delta must
label every line so the agent does not assume all prior text came from "the
user":

- Mark human lines and other agents' lines distinctly (e.g. a name prefix per
  line).
- State explicitly that this is a group conversation and that it is now this
  agent's turn to respond.

Getting these labels right is what keeps attribution and tone correct.

## Heterogeneous Roles

Each member's model / effort / permission is configured when the swarm is created
and stored on the group (`memberConfigs`), so members can have different roles
without new machinery — for example a read-only "planner/reviewer" member
alongside a write-enabled "doer" member, optionally on different models. The
existing BTW sidekick (a read-only side session for Claude, Codex, and
Antigravity) is the precedent for a non-writing secondary voice in a
conversation.

## Reused Machinery

- **Serialization**: `scopeChains` tail promises in `server.js`.
- **Streaming + per-message rendering**: SSE `segment` events.
- **Per-member options**: `server/lib/agent-options.js` `buildArgs`.
- **Agent execution**: `server/lib/agents.js` `runAgent` and per-agent runners,
  unchanged.
- **State persistence**: `server/lib/json-store.js`.

## Constraints And Risks

- **Prompt size.** Prompts ride to the CLI as a single argv token, capped by
  `PROMPT_MAX_BYTES` (default 100 KB; Linux argv ~128 KB). Plan B keeps each turn
  small by injecting only the delta; a very large delta (an agent that has been
  silent for a long time) must still be bounded or summarized before it hits the
  cap.
- **Cost.** One human message can fan out into several agent turns, multiplying
  token usage and time across multiple accounts. Surface the expected cost and
  apply a per-round turn budget; the existing quota watch already tracks usage.
- **Divergent memory.** Each agent only knows what it was told via injected
  deltas, so members' private memories diverge by design. Labeling and consistent
  delta injection are what keep the shared conversation coherent.
- **Termination.** The group is done when the turn queue is empty; there is no
  agent-initiated continuation in the manual-summon version, which keeps the stop
  condition simple.

## Out Of Scope (First Version)

- Agent-initiated summon chains (`@agent` emitted by an agent) and the loop /
  depth / budget guards they require.
- Parallel speakers.
- Facilitator / round-robin auto turn-taking.

## Backend Implementation (v1)

The orchestration layer ships in three small modules and reuses the single-agent
turn pipeline unchanged:

- `server/lib/groups.js` — group config (id, name, ordered members, the swarm's
  `workdir` work tree, and per-member `memberConfigs`) persisted per workspace via
  `json-store` (atomic 0o600). Members are validated agent keys; the count is
  capped (`MAX_MEMBERS`) and so is the number of groups per workspace.
  `memberConfigs` are structurally sanitized here (the route normalizes the ids),
  so the module stays agent-agnostic.
- `server/lib/group-turn.js` — pure helpers: `parseMentions` (`@key`, `@label`,
  `@all`), `deltaSince` (plan B), and `buildGroupPrompt` (speaker-labeled, byte
  bounded). No I/O, so the labeling is unit-tested directly.
- `server/routes/group.js` — endpoints + the round orchestrator. On create it
  validates the chosen work tree (`validateWorkdir`) and normalizes each member's
  config (`normalizeSettings`). It records the human message once, then runs each
  summoned member through `runAgentTurn` serialized on the group scope key
  (`${workdir}\0group:${groupId}`, keyed on the swarm's work tree). Three
  dependency overrides do all the group-specific work: `runAgent` resumes the
  member's own group session (`${workdir}\0${agentKey}\0${groupId}`) so private
  memory is preserved while history lands on the group transcript, `getSettings`
  returns the swarm's `memberConfigs[agent]` instead of the solo-chat store, and
  `broadcastScope` tags every event with `groupId`. `recordUserMessage: false`
  (a new `runAgentTurn` option) keeps the per-member delta prompt out of the
  transcript.

**Endpoints** (all under `requireAuth`, workdir from `X-Workdir`):

- `GET /api/groups`, `POST /api/groups` (`{name, members, workdir?, configs?}` —
  `workdir` is the chosen work tree, default the workspace; `configs` maps
  `agentKey → {model?, effort?, permission?}`),
  `POST /api/groups/members` (`{groupId, members, configs?}`),
  `POST /api/groups/delete` (`{groupId}`).
- `GET /api/group/history?groupId=`, `POST /api/group/clear` (`{groupId}`).
- `POST /api/group/chat` (`{groupId, prompt, requestId?}`) — streams SSE to the
  caller when `Accept: text/event-stream`; otherwise returns a JSON round
  summary. `POST /api/group/chat/cancel` (`{requestId}`) cancels the round.

**Event contract.** Per-member turns emit the usual `agent_start` / `agent_delta`
/ `agent_segment` / `agent_done` (etc.) events on the shared `/api/events`
stream, each carrying `groupId` plus the member as `agent` and `session.id =
groupId`. The human message is broadcast as `group_message`; a cancel emits
`group_cancelled`. A finished round **always** broadcasts `group_done` on the
shared stream (not only on the POST response), so every device viewing the group
reloads the authoritative transcript — this is what surfaces the final reply of
an agent that streamed no `agent_delta` (its result lives only in history, never
on the live stream) and what keeps other devices, which never see the POST
response, in sync. Transcript messages carry `metadata.author` (`human` or an
agent key) and `metadata.summonedBy`.

> **Wiring gotcha.** Every helper the router pulls off `routeContext` must
> actually be added to that object in `server.js` — `upsertHistoryMessage` was
> exported and used inside `agentTurnDependencies()` but missing from
> `routeContext`, so the first line of every round (`upsertHistoryMessage(...)`
> for the human message) threw `TypeError`, aborting the whole round before any
> agent ran or anything persisted. The `group-route.test.js` integration test
> mounts the real router + real `runAgentTurn` to guard this contract.

## Flutter Client (v1)

A dedicated screen reachable from the left drawer ("Swarm"). The drawer entry
lists every swarm in the current workspace as always-visible sub-entries
(`SwarmDrawerSection`); tapping one opens directly into that swarm
(`GroupChatScreen(initialGroupId:)`), and the list reloads when the workspace
changes (it watches `BotChatController.activeWorkdir`).

- `lib/core/models/group.dart` — `ChatGroup` model (incl. `workdir` and
  `memberConfigs`) + author-label helper.
- `lib/features/chat/group_chat_controller.dart` — owns the screen's state. It
  **sends the human message as plain JSON** (not SSE): because the round runs
  non-streaming on the server, every per-agent delta is mirrored on the shared
  `/api/events` stream tagged with `groupId`, so a single subscription renders
  both this device's and other devices' activity with no de-dup logic. Live
  bubbles are built from `agent_delta`/`agent_segment`; after `group_done` (or
  the POST resolving) the transcript is reloaded so the authoritative segments
  replace the live ones.
- `lib/features/chat/group_chat_screen.dart` — transcript with per-speaker
  attribution, a group switcher, create/manage-members/clear/delete actions, and
  a composer with one-tap `@member` / `@all` mention chips. The create form
  (`_SwarmFormDialog`) lets the user pick the work tree (a directory browser over
  `/api/workdir/browse`) and, per selected member, its model / effort / permission
  (catalogs fetched lazily via `fetchAgentOptions`).

The backend client gained `fetchGroups` / `createGroup` / `setGroupMembers` /
`deleteGroup` / `fetchGroupHistory` / `sendGroupMessage` / `cancelGroupMessage` /
`clearGroup` (`lib/core/backend/backend_client.dart`).
