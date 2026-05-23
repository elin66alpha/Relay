'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

// Best-effort detection of whether each agent CLI has a logged-in account, by
// inspecting the credential files the CLIs write on login. This never spawns
// the CLI, so it is cheap and side-effect free. Returns true/false when a
// credential file is readable, or null when login state cannot be determined
// (e.g. agy, which has no documented credential file we can rely on). A true
// here only means credentials exist on disk — it does not guarantee the token
// is still valid; an expired token is still caught at chat time as NOT_LOGGED_IN.
const CLAUDE_CREDS = path.join(os.homedir(), '.claude', '.credentials.json');
const CODEX_AUTH = path.join(os.homedir(), '.codex', 'auth.json');

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf-8'));
  } catch (_err) {
    return null;
  }
}

function claudeLoggedIn() {
  const oauth = (readJson(CLAUDE_CREDS) || {}).claudeAiOauth;
  return !!(oauth && (oauth.accessToken || oauth.refreshToken));
}

function codexLoggedIn() {
  const tokens = (readJson(CODEX_AUTH) || {}).tokens;
  return !!(tokens && tokens.access_token);
}

function authStatus(agentKey) {
  switch (agentKey) {
    case 'claude':
      return claudeLoggedIn();
    case 'codex':
      return codexLoggedIn();
    default:
      // agy and anything else: cannot determine without running the CLI.
      return null;
  }
}

module.exports = { authStatus };
