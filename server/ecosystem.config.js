// AgentDeck backend + optional cloudflared tunnel, managed by PM2.
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

function envValue(key) {
  if (process.env[key]) return process.env[key];
  const envPath = path.join(__dirname, '.env');
  try {
    const lines = fs.readFileSync(envPath, 'utf8').split(/\r?\n/);
    const prefix = `${key}=`;
    const line = lines.find((item) => item.startsWith(prefix));
    return line ? line.slice(prefix.length).trim() : '';
  } catch (_) {
    return '';
  }
}

function commandPath(command) {
  try {
    return execFileSync('sh', ['-lc', `command -v ${command}`], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch (_) {
    return '';
  }
}

const cloudflaredArgs =
  envValue('CLOUDFLARED_ARGS') || 'tunnel --url http://localhost:8787';
const cloudflaredBin = envValue('CLOUDFLARED_BIN') || commandPath('cloudflared') || 'cloudflared';
const tunnelMode = envValue('AGENTDECK_TUNNEL_MODE') || 'quick';

const apps = [
  {
    name: 'agentdeck-server',
    script: 'server.js',
    env_file: '.env',
    restart_delay: 5000,
    max_restarts: 10,
  },
];

if (tunnelMode !== 'none') {
  apps.push(
    {
      name: 'agentdeck-tunnel',
      script: cloudflaredBin,
      interpreter: 'none',
      env_file: '.env',
      args: cloudflaredArgs,
      restart_delay: 5000,
      max_restarts: 50,
    },
  );
}

module.exports = { apps };
