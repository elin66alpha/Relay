#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline/promises');
const crypto = require('crypto');
const QRCode = require('qrcode');
const qrcodeTerminal = require('qrcode-terminal');

require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

const { encryptCredential } = require('../lib/credential-file');
const {
  createToken,
  listTokenSummaries,
  revokeToken,
} = require('../lib/tokens');

const SERVER_DIR = path.resolve(__dirname, '..');
const ENV_PATH = path.join(SERVER_DIR, '.env');
const ENV_EXAMPLE_PATH = path.join(SERVER_DIR, '.env.example');

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) {
      args[key] = 'true';
    } else {
      args[key] = next;
      i += 1;
    }
  }
  return args;
}

function usage() {
  console.log(`Usage:
  npm run credential                 # Use PUBLIC_BASE_URL or detect Quick Tunnel URL, prompt for a password, print the credential QR

Options:
  --url <url>          Public URL (default: stable PUBLIC_BASE_URL, then Quick Tunnel log)
  --name <name>        Machine name shown in the app (default: hostname)
  --label <label>      Token label (default: machine name)
  --qr-out <path>      Output path for the QR PNG
  --json-out <path>    Output path for the copy/paste credential JSON
  --passphrase <text>  Credential password (min 6 chars; prompts interactively if omitted)
  --tunnel-name <name> PM2 process name of the cloudflared tunnel (default: relay-tunnel, then bot-app-tunnel)
  --list-tokens        List all tokens and their revocation state
  --revoke <id|token>  Revoke a token

Generating a new QR deletes old QR image files from server/credentials, but it
does not revoke existing device tokens. Revoke tokens explicitly with --revoke.
`);
}

// Auto-detect the Cloudflare Quick Tunnel public URL. cloudflared prints the URL
// to stderr, which PM2 captures in per-process logs. Quick Tunnel URLs rotate
// on every restart, so use the newest matching URL in the newest known log. A
// named Cloudflare Tunnel normally uses PUBLIC_BASE_URL instead.
const PM2_LOG_DIR = path.join(os.homedir(), '.pm2', 'logs');
const TRYCLOUDFLARE_RE = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/gi;

function detectTunnelUrl(args) {
  const names = [];
  const override = String(
    args['tunnel-name'] || process.env.TUNNEL_PM2_NAME || '',
  ).trim();
  if (override) names.push(override);
  names.push('relay-tunnel', 'bot-app-tunnel');

  const files = [];
  for (const name of names) {
    files.push(path.join(PM2_LOG_DIR, `${name}-error.log`));
    files.push(path.join(PM2_LOG_DIR, `${name}-out.log`));
  }
  const existing = files
    .filter((file) => fs.existsSync(file))
    .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);

  for (const file of existing) {
    let text;
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch (_err) {
      continue;
    }
    const matches = text.match(TRYCLOUDFLARE_RE);
    if (matches && matches.length) return matches[matches.length - 1];
  }
  return '';
}

function resolvePublicBaseUrl(args) {
  const explicit = String(args.url || '').trim();
  if (explicit) return { url: explicit, source: 'command line (--url)' };
  const envUrl = String(process.env.PUBLIC_BASE_URL || '').trim();
  if (envUrl && !TRYCLOUDFLARE_RE.test(envUrl)) {
    return { url: envUrl, source: '.env PUBLIC_BASE_URL' };
  }
  TRYCLOUDFLARE_RE.lastIndex = 0;
  const detected = detectTunnelUrl(args);
  if (detected) return { url: detected, source: 'cloudflared tunnel log' };
  if (envUrl) {
    return { url: envUrl, source: '.env PUBLIC_BASE_URL (may be stale)' };
  }
  throw new Error(
    'Could not determine the public URL. Make sure the tunnel is running and PUBLIC_BASE_URL is set, or pass --url explicitly.',
  );
}

const MIN_PASSPHRASE_LEN = 6;

function validatePassphrase(pass) {
  if (String(pass).length < MIN_PASSPHRASE_LEN) {
    throw new Error(`Password must be at least ${MIN_PASSPHRASE_LEN} characters.`);
  }
  return String(pass);
}

function ensureEnvFile() {
  if (fs.existsSync(ENV_PATH)) return;
  if (fs.existsSync(ENV_EXAMPLE_PATH)) {
    fs.copyFileSync(ENV_EXAMPLE_PATH, ENV_PATH);
  } else {
    fs.writeFileSync(ENV_PATH, '');
  }
}

function setEnvValue(content, key, value) {
  const escaped = String(value).replace(/\n/g, '');
  const line = `${key}=${escaped}`;
  const re = new RegExp(`^${key}=.*$`, 'm');
  if (re.test(content)) return content.replace(re, line);
  const suffix = content.endsWith('\n') || content.length === 0 ? '' : '\n';
  return `${content}${suffix}${line}\n`;
}

function updateEnv(values) {
  ensureEnvFile();
  let content = fs.readFileSync(ENV_PATH, 'utf8');
  for (const [key, value] of Object.entries(values)) {
    content = setEnvValue(content, key, value);
  }
  fs.writeFileSync(ENV_PATH, content);
}

async function readPassphrase(args) {
  if (process.env.RELAY_CREDENTIAL_PASSPHRASE) {
    return validatePassphrase(process.env.RELAY_CREDENTIAL_PASSPHRASE);
  }
  if (args.passphrase) return validatePassphrase(args.passphrase);
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  rl._writeToOutput = function _writeToOutput(stringToWrite) {
    if (rl.stdoutMuted) {
      rl.output.write(stringToWrite.replace(/[^\r\n]/g, '*'));
    } else {
      rl.output.write(stringToWrite);
    }
  };

  const ask = async (promptText) => {
    rl.stdoutMuted = false;
    const p = rl.question(promptText);
    rl.stdoutMuted = true;
    const ans = await p;
    return ans;
  };

  try {
    for (;;) {
      const first = await ask(`Set a credential password (min ${MIN_PASSPHRASE_LEN} chars): `);
      process.stdout.write('\n');
      if (String(first).length < MIN_PASSPHRASE_LEN) {
        console.log(`Password must be at least ${MIN_PASSPHRASE_LEN} characters. Try again.`);
        continue;
      }
      const second = await ask('Confirm password: ');
      process.stdout.write('\n');
      if (first !== second) {
        console.log('Passwords do not match. Try again.');
        continue;
      }
      return first;
    }
  } finally {
    rl.close();
  }
}

function safeFilename(name) {
  return String(name)
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '') || 'machine';
}

function printTokens() {
  const records = listTokenSummaries();
  if (records.length === 0) {
    console.log('No tokens configured.');
    return;
  }
  for (const record of records) {
    const state = record.revoked ? 'revoked' : 'active';
    console.log(`${record.id}\t${state}\t${record.label || '-'}`);
  }
}

function cleanOldCredentialFiles(dir) {
  fs.mkdirSync(dir, { recursive: true });
  for (const entry of fs.readdirSync(dir)) {
    if (/\.(botcred|json|png|svg|txt)$/i.test(entry)) {
      fs.rmSync(path.join(dir, entry), { force: true });
    }
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || args.h) {
    usage();
    return;
  }
  if (args['list-tokens']) {
    printTokens();
    return;
  }
  if (args.revoke) {
    const revoked = revokeToken(args.revoke);
    if (!revoked) {
      throw new Error('token not found in server/tokens.json');
    }
    console.log(`Revoked token: ${revoked.id} (${revoked.label || '-'})`);
    return;
  }

  const resolved = resolvePublicBaseUrl(args);
  const baseUrl = resolved.url.replace(/\/+$/, '');
  const parsedUrl = new URL(baseUrl);
  if (!['http:', 'https:'].includes(parsedUrl.protocol)) {
    throw new Error('public URL must start with http:// or https://');
  }

  const machineName = String(
    args.name || process.env.MACHINE_NAME || os.hostname(),
  ).trim();
  const machineId = String(
    process.env.MACHINE_ID || crypto.randomUUID(),
  ).trim();
  const passphrase = await readPassphrase(args);
  const label = String(args.label || machineName).trim() || machineName;
  const credentialsDir = path.join(SERVER_DIR, 'credentials');
  cleanOldCredentialFiles(credentialsDir);
  const tokenRecord = createToken({
    label,
  });
  const now = new Date().toISOString();

  updateEnv({
    MACHINE_ID: machineId,
    MACHINE_NAME: machineName,
    PUBLIC_BASE_URL: baseUrl,
  });

  const credential = {
    id: machineId,
    name: machineName,
    baseUrl,
    token: tokenRecord.token,
    createdAt: now,
  };
  const envelope = encryptCredential(credential, passphrase);
  // The QR code IS the credential (an encrypted envelope). Compact JSON keeps the
  // QR small enough to scan from a terminal/SSH. No plaintext credential file is
  // written - import happens entirely by scanning.
  const qrPayload = JSON.stringify(envelope);
  const qrPath = path.resolve(
    SERVER_DIR,
    args['qr-out'] ||
      path.join('credentials', `${safeFilename(machineName)}.relay.png`),
  );
  const jsonPath = path.resolve(
    SERVER_DIR,
    args['json-out'] ||
      path.join('credentials', `${safeFilename(machineName)}.relay.json`),
  );
  fs.mkdirSync(path.dirname(qrPath), { recursive: true });
  fs.mkdirSync(path.dirname(jsonPath), { recursive: true });
  await QRCode.toFile(qrPath, qrPayload, {
    errorCorrectionLevel: 'M',
    margin: 2,
    width: 1024,
  });
  fs.writeFileSync(jsonPath, `${qrPayload}\n`, { mode: 0o600 });

  console.log(`QR saved: ${qrPath}`);
  console.log(`Credential JSON saved: ${jsonPath}`);
  console.log(`Machine: ${machineName}`);
  console.log(`Public URL: ${credential.baseUrl} (source: ${resolved.source})`);
  console.log(`Token id: ${tokenRecord.id}`);
  console.log('Existing device tokens were left active. Use --revoke to disable an old device.');
  console.log('\nIn the app, tap "Scan QR", point it at the QR below, then enter the password you just set:\n');
  qrcodeTerminal.generate(qrPayload, { small: true });
  console.log('\nFor paste import, open the credential JSON file above, copy the whole file content, then paste it in the app.');
  console.log('Token appended to server/tokens.json; machine id and public URL written to server/.env.');
}

main().catch((err) => {
  console.error(`Error: ${err.message}`);
  process.exit(1);
});
