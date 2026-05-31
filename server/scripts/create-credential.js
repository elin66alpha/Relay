#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline/promises');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
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
  npm run credential                 # Auto-detect the Tailscale address, prompt for a password, print the credential QR

Options:
  --url <url>          Backend URL (default: auto-detected from Tailscale; use this for direct/VPS mode)
  --name <name>        Machine name shown in the app (default: hostname)
  --label <label>      Token label (default: machine name)
  --qr-out <path>      Output path for the QR PNG
  --passphrase <text>  Credential password (min 6 chars; prompts interactively if omitted)
  --list-tokens        List all tokens and their revocation state
  --revoke <id|token>  Revoke a token

Generating a new QR deletes old QR image files from server/credentials, but it
does not revoke existing device tokens. Revoke tokens explicitly with --revoke.
`);
}

// Auto-detect this machine's stable Tailscale address. Use the 100.x tailnet
// IPv4 first because it does not depend on client-side MagicDNS being enabled
// on Android/iOS. Fall back to the MagicDNS name when no IPv4 is available.
// Unlike a quick tunnel, this address is stable across restarts. Tailscale's
// WireGuard transport is end-to-end encrypted, so plain http over the tailnet is
// fine; the backend is never exposed to the public internet.
function runTailscale(args) {
  try {
    return execFileSync('tailscale', args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 5000,
    });
  } catch (_err) {
    return '';
  }
}

function detectTailscaleUrl(port) {
  const ip = runTailscale(['ip', '-4']).trim().split('\n')[0].trim();
  if (ip) return { url: `http://${ip}:${port}`, source: 'Tailscale IPv4' };

  let host = '';
  const statusJson = runTailscale(['status', '--json']);
  if (statusJson) {
    try {
      const status = JSON.parse(statusJson);
      if (status && status.Self && status.Self.DNSName) {
        host = String(status.Self.DNSName).replace(/\.$/, '');
      }
    } catch (_err) {
      // Fall through to no detected URL.
    }
  }
  return host
    ? { url: `http://${host}:${port}`, source: 'Tailscale MagicDNS' }
    : null;
}

function resolvePublicBaseUrl(args) {
  const port = String(process.env.PORT || '8787').trim() || '8787';
  const explicit = String(args.url || '').trim();
  if (explicit) return { url: explicit, source: 'command line (--url)' };
  const detected = detectTailscaleUrl(port);
  if (detected) return detected;
  const envUrl = String(process.env.PUBLIC_BASE_URL || '').trim();
  if (envUrl) {
    return { url: envUrl, source: '.env PUBLIC_BASE_URL (may be stale)' };
  }
  throw new Error(
    'Could not determine the backend address. Install Tailscale and run `tailscale up` ' +
      '(https://tailscale.com/download), then re-run. For a VPS / public host / own domain, ' +
      'pass the address explicitly with --url.',
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
  if (process.env.AGENTDECK_CREDENTIAL_PASSPHRASE) {
    return validatePassphrase(process.env.AGENTDECK_CREDENTIAL_PASSPHRASE);
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
    if (/\.(botcred|png|svg|txt)$/i.test(entry)) {
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
      path.join('credentials', `${safeFilename(machineName)}.agentdeck.png`),
  );
  fs.mkdirSync(path.dirname(qrPath), { recursive: true });
  await QRCode.toFile(qrPath, qrPayload, {
    errorCorrectionLevel: 'M',
    margin: 2,
    width: 1024,
  });

  console.log(`QR saved: ${qrPath}`);
  console.log(`Machine: ${machineName}`);
  console.log(`Public URL: ${credential.baseUrl} (source: ${resolved.source})`);
  console.log(`Token id: ${tokenRecord.id}`);
  console.log('Existing device tokens were left active. Use --revoke to disable an old device.');
  console.log('\nIn the app, tap "Scan QR", point it at the QR below, then enter the password you just set:\n');
  qrcodeTerminal.generate(qrPayload, { small: true });
  console.log('\nToken appended to server/tokens.json; machine id and public URL written to server/.env.');
}

main().catch((err) => {
  console.error(`Error: ${err.message}`);
  process.exit(1);
});
