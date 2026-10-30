'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { generateKeyPairSync } = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// Catches firebase-admin API changes, which no other test reaches: a valid
// service account must still initialize the messaging app.
test('a service account file enables Firebase messaging', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-fcm-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const file = path.join(dir, 'service-account.json');
  fs.writeFileSync(file, JSON.stringify({
    type: 'service_account',
    project_id: 'relay-test',
    client_email: 'relay@relay-test.iam.gserviceaccount.com',
    private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
  }));
  process.env.FCM_SERVICE_ACCOUNT_FILE = file;

  assert.equal(require('../lib/fcm').isEnabled(), true);
});
