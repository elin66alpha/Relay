'use strict';

// Shared Antigravity (`agy`) on-disk locations. usage.js (quota plan label) and
// agent-options.js (default model) both need the model configured in agy's own
// settings.json, so the path + read live here once instead of in each module.

const fs = require('fs');
const os = require('os');
const path = require('path');

const AGY_DIR = path.join(os.homedir(), '.gemini', 'antigravity-cli');
const AGY_SETTINGS = path.join(AGY_DIR, 'settings.json');

// The model label configured in agy's settings.json, or '' when unset or
// unreadable. Best-effort: a missing/corrupt file is just "no preference".
function configuredAgyModel() {
  try {
    const parsed = JSON.parse(fs.readFileSync(AGY_SETTINGS, 'utf-8'));
    return typeof parsed.model === 'string' ? parsed.model : '';
  } catch (_err) {
    return '';
  }
}

module.exports = { AGY_DIR, configuredAgyModel };
