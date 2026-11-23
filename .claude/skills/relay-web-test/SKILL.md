---
name: relay-web-test
description: Test the Relay Web client in a real headless browser against the live PM2 backend. Use after any change that affects what the client shows or does (Flutter UI, client logic, or a route the client calls), when asked to "test in the browser", "run the web smoke", or to confirm a change works for real rather than only in widget tests.
---

# Relay real-browser test

Widget tests miss layout, canvas rendering, real HTTP/SSE and real agent replies. This
flow runs the built Web client in headless Chromium against the running `relay-server`.

## Boundaries (each has a why)

- Test sessions use only `~/playground/relay-web-test/`: the rest of `~/playground`
  holds the user's own files, and real agents write in their workdir.
- Never read `server/tokens.json`, `server/.env` or credential files. `scripts/dev/lib/relay_web.js`
  creates a temporary `relay-web-test` token and deletes it afterwards.
- Every session or Swarm you create is named with the `[web-test]` prefix, so cleanup can
  find it and never touches the user's own sessions. Cleanup deletes only that prefix.
- Real sends use Claude Code with the cheapest (haiku) model and tiny prompts: each send
  costs real quota.
- Screenshots contain real conversation content: they stay in
  `~/playground/relay-web-test/shots/` and are never committed.
- Tell the user before restarting `relay-server` (it interrupts their running sessions).
  Rebuilding the Web build in place is allowed; it is what their own browsers load.
- Not part of CI.

## Steps

1. If the change touched Flutter code, rebuild the Web client:
   `(cd app/shell && flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn)`.
2. If the change touched backend code, tell the user, then `pm2 restart relay-server`.
3. Run the fixed smoke and check its own exit code (never pipe it into `tail`):
   `node scripts/dev/web_smoke.js` → exit 0, every line `PASS`. It visits home, chat,
   files, browser and settings at desktop 1440×960 and mobile 400×820, sends one real
   message on desktop, and fails on console errors, page errors, failed requests and
   HTTP ≥ 400 responses.
4. Exploratory check for this change: write a throwaway script in
   `~/playground/relay-web-test/` that requires
   this checkout's `scripts/dev/lib/relay_web.js` by absolute path (`createTestToken`, `openRelayPage`,
   `api`, `cleanupTestData`, `deleteTestToken`), drives exactly the screens and actions the
   change affects, and screenshots each step. Always clean up and delete the token in
   `finally`.
5. Look at the screenshots with the Read tool. Judge layout, text, overflow and state
   yourself; a passing script is not enough.
6. Report to the user: smoke result, what the exploratory script did, the screenshots that
   prove it, and anything still unverified.

## Flutter Web notes

- The app paints to a canvas. Click `flt-semantics-placeholder` once to build the semantics
  tree, then target `getByRole('button', { name })` and `getByRole('textbox')`. Use
  coordinates only where no label exists.
- Labels come from `app/core/lib/core/i18n/app_strings.dart`; the test page is in English.
- On mobile width the drawer must be opened first.
- Prefer waiting for a label to appear over fixed sleeps.
