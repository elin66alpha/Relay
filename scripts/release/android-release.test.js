'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { createHash } = require('node:crypto');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

test('Android release signs the matching draft and rejects the wrong certificate', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-android-release-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const write = (file, text, mode) => {
    const target = path.join(root, file);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, text, { mode: mode || 0o644 });
    return target;
  };
  const copy = (name) => write(`scripts/release/${name}`, fs.readFileSync(path.join(__dirname, name)));
  copy('add_signed_android.sh');
  copy('check_versions.js');
  write('server/package.json', '{"version":"1.2.3"}');
  write('server/package-lock.json', '{"version":"1.2.3","packages":{"":{"version":"1.2.3"}}}');
  write('app/shell/pubspec.yaml', 'version: 1.2.3+5\n');
  write('app/shell/android/key.properties', 'fixture signing configuration');
  write('app/shell/android/app/google-services.json', 'fixture private Firebase configuration');
  write('app/core/lib/features/settings/app_settings_screen.dart', "const _applicationVersion = '1.2.3';");
  write('app/core/lib/features/settings/whats_new_screen.dart', "const List<_Release> _zhReleases = [version: '1.2.3'];\nconst List<_Release> _enReleases = [version: '1.2.3'];");
  write('docs/CHANGELOG.md', '## 1.2.3 - today\n');
  const assets = ['install.sh', 'relay-backend-setup-v1.2.3.tar.gz', 'relay-windows-x64-v1.2.3.zip', 'relay-backend-windows-x64-v1.2.3.zip', 'relay-desktop_1.2.3_amd64.deb'];
  let sums = '';
  for (const asset of assets) {
    write(`fixtures/${asset}`, `fixture ${asset}`);
    sums += `${createHash('sha256').update(`fixture ${asset}`).digest('hex')}  ${asset}\n`;
  }
  write('fixtures/SHA256SUMS', sums);
  write('bin/git', '#!/bin/sh\ncase "$1 $2" in\n  "rev-parse HEAD") echo abc123 ;;\n  "worktree add") mkdir -p "$4/app/shell/android"; touch "$4/.git" ;;\nesac\n', 0o755);
  write('bin/flutter', '#!/bin/sh\n[ ! -e android/app/google-services.json ] || exit 1\nmkdir -p build/app/outputs/flutter-apk\nprintf signed-apk > build/app/outputs/flutter-apk/app-release.apk\n', 0o755);
  write('bin/gh', `#!/bin/bash
set -eu
case "$1 $2" in
  'repo view') echo owner/Relay ;;
  'release view')
    if [[ "$*" == *isDraft* ]]; then echo true; else echo '> Android APK is pending local signing. Do not publish this draft yet.'; fi ;;
  'api repos/owner/Relay/git/ref/tags/v1.2.3') echo abc123 ;;
  'release download')
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --dir ]; then target="$2"; break; fi
      shift
    done
    cp "$RELAY_TEST_FIXTURES"/* "$target"/ ;;
  'release upload')
    for arg in "$@"; do case "$arg" in *.apk|*/SHA256SUMS) cp "$arg" "$RELAY_TEST_UPLOADS"/ ;; esac; done ;;
  'release edit') touch "$RELAY_TEST_UPLOADS/edited" ;;
  *) echo "unexpected gh call" >&2; exit 1 ;;
esac
`, 0o755);
  const cert = '3e4dea3f6cd50fd30b25a168ba9eb2c14a14ecb8f786ffcb4e3c1836275a720f';
  write('sdk/build-tools/35.0.0/apksigner', '#!/bin/sh\necho "Signer #1 certificate SHA-256 digest: $RELAY_TEST_CERT"\n', 0o755);
  write('sdk/build-tools/35.0.0/aapt', '#!/bin/sh\necho "package: name=\x27dev.relay.app\x27 versionCode=\x275\x27 versionName=\x271.2.3\x27"\n', 0o755);
  fs.mkdirSync(path.join(root, 'uploads'));
  const run = (certificate) => spawnSync('bash', [path.join(root, 'scripts/release/add_signed_android.sh')], {
    encoding: 'utf8',
    env: {
      ...process.env, PATH: `${path.join(root, 'bin')}:${process.env.PATH}`,
      ANDROID_HOME: path.join(root, 'sdk'), RELAY_TEST_FIXTURES: path.join(root, 'fixtures'),
      RELAY_TEST_UPLOADS: path.join(root, 'uploads'), RELAY_TEST_CERT: certificate,
    },
  });
  const rejected = run('wrong-certificate');
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /not signed with the Relay release certificate/);
  assert.deepEqual(fs.readdirSync(path.join(root, 'uploads')), []);

  const accepted = run(cert);
  assert.equal(accepted.status, 0, accepted.stderr);
  assert.ok(fs.existsSync(path.join(root, 'uploads', 'relay-android-v1.2.3.apk')));
  assert.ok(fs.existsSync(path.join(root, 'uploads', 'edited')));
  const updated = fs.readFileSync(path.join(root, 'uploads', 'SHA256SUMS'), 'utf8');
  assert.match(updated, new RegExp(`${createHash('sha256').update('signed-apk').digest('hex')}  relay-android-v1.2.3\\.apk`));

  fs.copyFileSync(path.join(root, 'uploads', 'SHA256SUMS'), path.join(root, 'fixtures', 'SHA256SUMS'));
  const retry = run(cert);
  assert.equal(retry.status, 0, retry.stderr);
});
