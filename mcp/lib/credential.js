'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');

// Same envelope and limits the app accepts (credential_file_codec.dart), so a
// credential that imports in the app opens here with the same password.
const FORMAT = 'relay.credentials.v1';

function credentialError(message) {
  const err = new Error(message);
  err.code = 'CREDENTIAL_INVALID';
  return err;
}

function readEnvelope(source) {
  const text = String(source || '').trim();
  if (!text) throw credentialError('RELAY_CREDENTIAL is not set: paste the Relay credential JSON or its file path.');
  const raw = text.startsWith('{') ? text : fs.readFileSync(text, 'utf8');
  try {
    return JSON.parse(raw);
  } catch (_err) {
    throw credentialError('The credential is not valid JSON.');
  }
}

function base64Field(value, field) {
  if (typeof value !== 'string' || !value.trim()) {
    throw credentialError(`The credential is missing ${field}.`);
  }
  return Buffer.from(value, 'base64');
}

function decryptCredential(source, password) {
  if (!String(password || '').trim()) {
    throw credentialError('RELAY_CREDENTIAL_PASSPHRASE is not set: enter the credential password.');
  }
  const envelope = readEnvelope(source);
  if (!envelope || envelope.format !== FORMAT) {
    throw credentialError('This is not an encrypted Relay credential.');
  }
  const kdf = envelope.kdf || {};
  const cipher = envelope.cipher || {};
  if (kdf.name !== 'pbkdf2-sha256' || cipher.name !== 'aes-256-gcm') {
    throw credentialError('The credential uses an unsupported encryption format.');
  }
  const iterations = Number(kdf.iterations);
  if (!Number.isInteger(iterations) || iterations < 10000 || iterations > 2000000) {
    throw credentialError('The credential KDF parameters are outside the supported safety range.');
  }
  const salt = base64Field(kdf.salt, 'salt');
  const nonce = base64Field(cipher.nonce, 'nonce');
  const tag = base64Field(cipher.tag, 'tag');
  const ciphertext = base64Field(cipher.ciphertext, 'ciphertext');
  let payload;
  try {
    const key = crypto.pbkdf2Sync(String(password), salt, iterations, 32, 'sha256');
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonce);
    decipher.setAuthTag(tag);
    payload = JSON.parse(Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8'));
  } catch (_err) {
    throw credentialError('Credential decryption failed. Check the credential JSON and password.');
  }
  return validateMachine(payload.machine || payload);
}

function validateMachine(machine) {
  const token = String((machine && machine.token) || '').trim();
  let url;
  try {
    url = new URL(String(machine.baseUrl || '').trim());
  } catch (_err) {
    throw credentialError('The credential has no valid baseUrl.');
  }
  if (!['http:', 'https:'].includes(url.protocol) || !token) {
    throw credentialError('The credential has no valid baseUrl or token.');
  }
  // A Quick Tunnel URL changes on every cloudflared restart, so a credential
  // holding one stops working without notice.
  if (url.hostname.endsWith('.trycloudflare.com')) {
    throw credentialError(
      'Relay MCP cannot use a Cloudflare Quick Tunnel (trycloudflare.com): its address changes on every restart. ' +
        'Give the backend a fixed PUBLIC_BASE_URL (named tunnel, domain, or LAN/Tailscale address) and create a new credential.',
    );
  }
  return {
    id: String(machine.id || ''),
    name: String(machine.name || url.hostname),
    baseUrl: url.href.replace(/\/+$/, ''),
    token,
  };
}

module.exports = { decryptCredential };
