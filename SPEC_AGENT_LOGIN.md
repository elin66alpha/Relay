# SPEC: Agent install/login status + in-app login (Relay)

Owner hand-off spec for the agent-credentials feature. Two phases. **Do Phase 1
first, commit, message the lead, then do Phase 2.** Keep changes minimal, reuse
existing code, and add tests per phase. Run `node --test` (server) and
`flutter analyze` + `flutter test` clean before marking a phase done.

## Goal

Per machine, surface for every CLI agent (claude, codex, agy, opencode, hermes)
**two status lights**:

1. **Installed?** — is the CLI binary present on the host.
2. **Authed?** — is it logged in (OAuth) / does it have an API key.

Then gate the whole app on this status:

- **Not installed** → everywhere (single-agent chat AND swarm) show the agent
  greyed-out / unselectable.
- **Installed but not authed** → also unselectable, but with a prompt:
  - OAuth agents (claude/codex/agy) → "needs login" + a login entry.
  - API-key agents (hermes) → "needs API key/provider".
- **opencode special case** → it has free models, so it is **usable even with no
  API key**. Never prompt for a key; once installed it counts as usable.

And add the **login / API-key entry UI**:

- A single login entry on the **home page** (appears once).
- In **Manage Credentials**, per machine, the per-agent login / key entry.
- OAuth login uses **PTY-bridged CLI login** (see Phase 2).
- hermes uses **provider picker + API key**. opencode key is optional.

## Agent / auth facts (verified)

Registry: `server/lib/agents.js` → `const AGENTS` (claude, codex, agy stable;
opencode, hermes `experimental: true`). `DEFAULT_AGENT = 'claude'`.

Install detection already exists: `commandExists(bin)` / `locateBin(bin)` in
`server/lib/agents.js` (PATH scan + `BIN_FALLBACKS` for opencode/hermes). Bins:
claude, codex, agy, opencode, hermes.

Credential locations / auth model:

| agent | authKind | authed = | login command |
|-------|----------|----------|---------------|
| claude | oauth | `~/.claude/.credentials.json` → `claudeAiOauth.accessToken` present (and refreshToken) | `claude login` (interactive, prints URL) |
| codex | oauth | `~/.codex/auth.json` → `tokens.access_token` present | `codex login` |
| agy | oauth | `~/.gemini/antigravity-cli/antigravity-oauth-token` exists & non-empty | **investigate exact agy login cmd** (e.g. `agy login` or first-run auth) |
| hermes | apiKey | `~/.hermes/auth.json` has a key / `~/.hermes/config.yaml` has provider+key | **investigate hermes config format** (provider+key) |
| opencode | apiKeyOptional | always usable once installed (free models); `~/.config/opencode/opencode.jsonc` may hold a key | optional |

Existing per-agent CLI catalog: `server/lib/agent-options.js` → `const CLI`
(bin/versionArgs/updateArgs).

## Phase 1 — status detection + gating (read-only, low risk; ship first)

### Backend

1. New module `server/lib/agent-status.js` (unit-tested) exporting a function
   that returns, for each agent key, `{ installed, authed, authKind }`.
   - `installed`: reuse `commandExists` from agents.js (export it if needed).
   - `authed`: per-agent credential check from the table above. For opencode,
     `authed` is effectively "usable" — return `authed: true` once installed (it
     has free models). Keep detection pure & cheap (fs.existsSync / JSON parse in
     try/catch, no network). Cache briefly (mirror `locateBinCache`, 60s TTL) so
     `/api/agents` stays fast.
   - Do NOT read/dump token *values*; only check presence/shape.

2. Extend `GET /api/agents` (`server/routes/meta.js`, uses `listAgents()` in
   `agents.js`). Currently it **hides** experimental agents until installed and
   returns only `{key,label,description}`. Change so it returns **all** known
   agents (claude, codex, agy, opencode, hermes) each with:
   `{ key, label, description, installed, authed, authKind, usable }`
   where `usable = installed && (authed || key === 'opencode')`.
   Keep `defaultAgent`. Keep payload shape backward-compatible (only add fields).

3. Server tests in `server/test/` for `agent-status.js` (mock fs/home) and for
   the `/api/agents` shape.

### Frontend

4. Extend `lib/core/models/cli_agent.dart` `CliAgent`: add
   `installed`, `authed`, `usable`, `authKind` (default safe values in
   `fromJson` so old payloads still parse). Keep `defaultCliAgents` /
   `knownCliAgents` for offline fallback.

5. `lib/features/cli_agents/cli_agents_controller.dart` already loads
   `/api/agents` via `backend_client.fetchAgents()`
   (`lib/core/backend/backend_client.dart:1367`). Carry the new fields through.

6. **Two status lights** per agent (red/green dots): one for installed, one for
   authed/usable. Add a small reusable widget (e.g. `AgentStatusLights`). Show it
   in the agent list (`lib/features/cli_agents/cli_agents_drawer.dart`) and in
   Manage Credentials (Phase 2 surface).

7. **Global gating** — an agent that is not `usable` must be unselectable and
   greyed everywhere:
   - Single-agent selector: `lib/features/chat/agent_controls.dart` (the
     `InkWell`/onTap agent picker).
   - Swarm member selection: `lib/features/chat/group_chat_screen.dart`.
   Show the right hint when tapped/long-pressed: not installed → unavailable;
   installed & !authed → "needs login" (oauth) / "needs API key" (hermes);
   opencode never blocked for missing key. Add i18n strings in
   `lib/core/i18n/app_strings.dart` (pattern: `isZh ? '中文' : 'English'`).

8. Flutter unit/widget tests for the model parsing and the gating predicate.

## Phase 2 — login + API-key entry (stateful; do after Phase 1 is merged)

### UI

- **Home page**: one login/credentials entry point (appears once). Find the home
  surface (`lib/app.dart` / home screen) and add a single entry that routes to
  Manage Credentials.
- **Manage Credentials per machine**:
  `lib/features/machines/machine_credentials_screen.dart` +
  `machine_credentials_controller.dart`. Add a per-agent section showing the two
  lights and a login / key action.

### OAuth login (claude/codex/agy) — PTY-bridged CLI login

- Backend spawns the CLI's own login in a pseudo-terminal so it emits its auth
  URL even when not attached to a TTY. **Reuse the existing pattern**:
  `server/lib/usage.js` already drives `script -qfec "<cmd>" /dev/null` for the
  agy probe (Linux). Mirror it (or add `node-pty` if cleaner — not currently a
  dep).
- Stream the captured auth URL to the app over the existing SSE infra
  (`writeStreamEvent` / `text/event-stream` in `server/lib/agent-turn.js`). The
  app shows the URL (tap to open browser); the user authorizes and pastes the
  code back; the backend writes it to the PTY stdin to finish login.
- New route(s) under `server/routes/` (e.g. `routes/auth.js`): start-login
  (SSE), submit-code, and a status endpoint. Investigate each CLI's exact login
  command and prompts (claude `login`, codex `login`, agy auth) — drive one at a
  time; fail clearly per-agent.
- After success, the credential file appears and the Phase-1 `authed` check flips
  green (no extra wiring needed).

### API-key entry (hermes / opencode)

- hermes: provider picker + API key field → write to hermes' config
  (`~/.hermes/config.yaml` / `auth.json` — investigate exact format) atomically
  (tmp+rename, mode 0600).
- opencode: optional key field; never blocks usage.

### Tests

- Backend: route handlers with a fake PTY/child (don't hit real OAuth). Config
  writers for hermes.
- Frontend: the login dialog state machine (idle → url shown → code submitted →
  done/error) with a fake backend.

## Constraints

- Reuse existing helpers (`commandExists`, SSE streaming, atomic file writes,
  i18n pattern). Do not duplicate.
- Never print/log credential token *values*.
- Keep `/api/agents` backward-compatible (add fields only).
- Match surrounding code style; keep diffs tight.
- Each phase: `node --test` (in `server/`) and `flutter analyze` + `flutter test`
  must pass before completion.
- Do not touch unrelated files. The main working tree has unrelated uncommitted
  work; you are on an isolated worktree branched from HEAD — ignore that.

## Coordination Protocol

- Use `clawteam task list relay-login --owner codex1` to see your tasks.
- Starting a task: `clawteam task update relay-login <task-id> --status in_progress`
- Before marking a task completed, commit your changes in this repository with git.
- Use a clear commit message, e.g. `git add -A && git commit -m "Implement <task summary>"`.
- Finishing a task: `clawteam task update relay-login <task-id> --status completed`
- When you finish all tasks, send a summary to the leader:
  `clawteam inbox send relay-login lead "All tasks completed. <brief summary>"`
- If you are blocked or need help, message the leader:
  `clawteam inbox send relay-login lead "Need help: <description>"`
- After finishing work, report your costs: `clawteam cost report relay-login --input-tokens <N> --output-tokens <N> --cost-cents <N>`
- Before finishing, save your session: `clawteam session save relay-login --session-id <id>`
