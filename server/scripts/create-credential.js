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
  revokeTokensByLabel,
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
  console.log(`用法:
  npm run credential                 # 自动探测隧道地址，提示设置密码，输出凭证二维码

可选参数:
  --url <url>          手动指定公网地址（默认自动从 cloudflared 隧道日志探测）
  --name <name>        app 里显示的机器名（默认主机名）
  --label <label>      token 标签（默认机器名）
  --qr-out <path>      二维码 PNG 输出路径
  --passphrase <text>  凭证密码（至少 6 位；省略则交互输入）
  --list-tokens        列出所有 token 及吊销状态
  --revoke <id|token>  吊销一个 token
`);
}

// 自动探测 cloudflared quick tunnel 的公网地址：cloudflared 把 URL 打到 stderr，
// 由 PM2 落在 agentdeck-tunnel 的日志里。取最后一次出现的（即当前隧道）。
const TUNNEL_LOG_FILES = [
  path.join(os.homedir(), '.pm2', 'logs', 'agentdeck-tunnel-error.log'),
  path.join(os.homedir(), '.pm2', 'logs', 'agentdeck-tunnel-out.log'),
];

function detectTunnelUrl() {
  const re = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/gi;
  for (const file of TUNNEL_LOG_FILES) {
    let text;
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch (_err) {
      continue;
    }
    const matches = text.match(re);
    if (matches && matches.length) return matches[matches.length - 1];
  }
  return '';
}

function resolvePublicBaseUrl(args) {
  const explicit = String(args.url || '').trim();
  if (explicit) return explicit;
  const detected = detectTunnelUrl();
  if (detected) return detected;
  const envUrl = String(process.env.PUBLIC_BASE_URL || '').trim();
  if (envUrl) return envUrl;
  throw new Error(
    '无法自动探测公网隧道地址。请确认 agentdeck-tunnel 正在运行（pm2 status），或用 --url 手动指定。',
  );
}

const MIN_PASSPHRASE_LEN = 6;

function validatePassphrase(pass) {
  if (String(pass).length < MIN_PASSPHRASE_LEN) {
    throw new Error(`密码至少 ${MIN_PASSPHRASE_LEN} 位。`);
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
  try {
    for (;;) {
      const first = await rl.question(`设置凭证密码（至少 ${MIN_PASSPHRASE_LEN} 位）: `);
      if (String(first).length < MIN_PASSPHRASE_LEN) {
        console.log(`密码至少 ${MIN_PASSPHRASE_LEN} 位，请重试。`);
        continue;
      }
      const second = await rl.question('再次输入确认: ');
      if (first !== second) {
        console.log('两次输入不一致，请重试。');
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

  const baseUrl = resolvePublicBaseUrl(args).replace(/\/+$/, '');
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
  const revoked = revokeTokensByLabel(label);
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
  // 二维码就是凭证本体（加密信封）。用紧凑 JSON 减小二维码尺寸，方便从终端/SSH 扫。
  // 不再产出明文凭证文件——导入完全走扫码。
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

  console.log(`二维码已保存: ${qrPath}`);
  console.log(`机器: ${machineName}`);
  console.log(`公网地址: ${credential.baseUrl}（自动探测）`);
  console.log(`Token id: ${tokenRecord.id}`);
  if (revoked.length > 0) {
    console.log(`已吊销 ${label} 的旧 token: ${revoked.length} 个`);
  }
  console.log('\n在 app 里点「扫描二维码」对准下面的二维码，然后输入刚设置的密码:\n');
  qrcodeTerminal.generate(qrPayload, { small: true });
  console.log('\ntoken 已追加到 server/tokens.json；机器 id 与公网地址已写入 server/.env。');
}

main().catch((err) => {
  console.error(`Error: ${err.message}`);
  process.exit(1);
});
