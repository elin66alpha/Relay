# Relay agent guide

Read ENGINEERING.md before any change. It is the engineering contract for this repository.

This file tells an agent that picks up this workspace how we work together: what
is safe to touch, how to check a change, and what to update with it. What Relay
is, its modules, and the constraints on them are in `ENGINEERING.md`; they are
not repeated here, because two copies drift apart.

Relay is a Flutter client plus a self-hosted Node.js backend for controlling
Claude Code, Codex, Cursor, OpenCode, and Hermes on the backend machine. Keep
public usage guidance in the root READMEs, operational detail in
`docs/handbook.md`, and security guarantees in `docs/SECURITY.md`.

## Working safely

- Never commit hosts, tokens, QR credentials, API keys, CLI login files, or
  generated backend state, because they expose private deployment details,
  account access, or conversation content.
- Preserve unrelated working-tree changes. This repository is often used while
  agents are actively running against it.
- Treat mobile, Web, desktop, and all backend operating systems as clients of
  the same HTTP/SSE, credential, session, and workdir model.
- Prefer focused tests while iterating. `scripts/dev/build_flow.sh` also
  rebuilds Web, restarts PM2, and builds an APK. ADB installation is opt-in with
  `INSTALL_APK=1`, so run the script only when that full local deployment flow
  is intended.
- Update `ENGINEERING.md` in the same change when a module, interface, feature,
  or verification step changes, so the next agent starts from a true map.

## Useful commands

```bash
# Client: screens, logic and tests live in app/core; app/shell is the runnable app.
(cd app/core && flutter pub get && flutter analyze --no-pub && flutter test --no-pub)
(cd app/core && flutter test --no-pub test/agent_controls_test.dart)
(cd app/shell && flutter pub get && flutter analyze --no-pub)

(cd server && git ls-files '*.js' | xargs -r -n1 node --check)
npm --prefix server run lint
npm --prefix server test
npm --prefix server start

# Relay MCP (stdio, no dependencies); lint reuses the backend's ESLint.
npm --prefix mcp test
server/node_modules/.bin/eslint -c server/eslint.config.js mcp

(cd app/shell && flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn)
./scripts/dev/build_flow.sh
```

The Web flags are intentional: Relay disables the service worker to avoid stale
clients and bundles CanvasKit locally instead of depending on gstatic.

Test files are `server/test/*.test.js`. Helper processes live in
`server/test/fixtures/`, which the runner would otherwise try to execute as
tests.

## Verification expectations

- Flutter-only changes: format touched Dart files, run analyze, then focused and
  full Flutter tests when practical.
- Backend changes: run `node --check` on touched JavaScript,
  `npm --prefix server run lint`, and `npm --prefix server test`.
- Cross-stack API changes: verify both suites and keep old payload parsing safe
  when adding response fields. `mcp/` is also a client of the API: run its
  tests when a route it calls changes.
- Changes to what the Web client shows or does: also run the real-browser flow
  in `.claude/skills/relay-web-test/SKILL.md` (`node scripts/dev/web_smoke.js`
  against the live backend, then a focused exploratory script), because widget
  tests miss rendering, real HTTP/SSE and real agent replies. Not part of CI.
- Documentation changes: verify local Markdown links, commands, environment
  names, English/Chinese README parity, and the in-app tutorial articles in
  `app/core/assets/tutorial/{en,zh}/` against code rather than old docs.
- Feature changes: update the tutorial article that describes the feature, in
  both languages, in the same change; a new feature gets a new article (same
  file name in `en/` and `zh/`, front matter as in `tutorial_screen.dart`).
  `node scripts/release/check_docs.js` checks the pairing and links.
- Release bumps update these files together:
  `app/shell/pubspec.yaml`, `server/package.json`, `mcp/package.json`, `_applicationVersion` in
  `app/core/lib/features/settings/app_settings_screen.dart`, and a
  `docs/CHANGELOG.md` entry.
- Dependabot pull requests merge into the release branch in development, never
  straight into `main`. When a new release branch starts, point every
  `target-branch` in `.github/dependabot.yml` at it, on `main`, where
  Dependabot reads it.
- `.github/workflows/ci.yml` runs the verification commands on pull requests.
  Update it when those commands change so CI keeps checking the same commands.

## Local state and secrets

Generated files under `server/` include `.env`, `tokens.json`, credentials,
agent/chat sessions, history, settings, context windows, reported models,
Relay's Cursor config (`cursor-config/`), groups, quota state/schedules, usage cache, and push/FCM stores. They are deployment state,
not fixtures. Keep them, along with any referenced FCM service-account JSON,
out of patches and release archives. `server/models-extra.json` is also a local
override, not a shared catalog. The Android release keystore and
`app/shell/android/key.properties` are signing secrets: never commit them or
upload them anywhere except the repository's `ANDROID_*` GitHub Actions Secrets
that the release workflow reads; `app/shell/android/key.properties.example` is
the template.
