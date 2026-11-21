'use strict';

// Windows has no PM2 or launchd to restart a backend that exits, so
// scripts/install/windows/lib/common.ps1 starts server.js through this: it runs
// the backend and starts it again five seconds after it exits. Stopping Relay
// kills this process and the backend together (taskkill /T).
const { spawn } = require('child_process');
const path = require('path');

const serverDir = path.join(__dirname, '..');
const RESTART_DELAY_MS = 5000;

function run() {
  const child = spawn(process.execPath, ['server.js'], { cwd: serverDir, stdio: 'inherit', windowsHide: true });
  child.on('exit', (code, signal) => {
    console.error(`${new Date().toISOString()} Relay backend exited (${signal || code}); starting it again in 5 seconds.`);
    setTimeout(run, RESTART_DELAY_MS);
  });
}

run();
