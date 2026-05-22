'use strict';

const crypto = require('crypto');

const FORMAT = 'agentdeck.credentials.v1';
const KDF_NAME = 'pbkdf2-sha256';
const CIPHER_NAME = 'aes-256-gcm';
const PBKDF2_ITERATIONS = 210000;

function encryptCredential(machine, passphrase) {
  if (!passphrase || !String(passphrase).trim()) {
    throw new Error('passphrase is required');
  }
  const payload = Buffer.from(JSON.stringify({
    machine,
    createdAt: new Date().toISOString(),
  }));
  const salt = crypto.randomBytes(16);
  const nonce = crypto.randomBytes(12);
  const key = crypto.pbkdf2Sync(
    String(passphrase),
    salt,
    PBKDF2_ITERATIONS,
    32,
    'sha256',
  );
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  const ciphertext = Buffer.concat([cipher.update(payload), cipher.final()]);
  const tag = cipher.getAuthTag();

  return {
    format: FORMAT,
    kdf: {
      name: KDF_NAME,
      iterations: PBKDF2_ITERATIONS,
      salt: salt.toString('base64'),
    },
    cipher: {
      name: CIPHER_NAME,
      nonce: nonce.toString('base64'),
      tag: tag.toString('base64'),
      ciphertext: ciphertext.toString('base64'),
    },
  };
}

module.exports = {
  CIPHER_NAME,
  FORMAT,
  KDF_NAME,
  PBKDF2_ITERATIONS,
  encryptCredential,
};
