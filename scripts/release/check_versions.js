'use strict';

const fs = require('node:fs');
const path = require('node:path');

function checkVersions(root) {
  const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
  const pkg = JSON.parse(read('server/package.json'));
  const lock = JSON.parse(read('server/package-lock.json'));
  const version = pkg.version;
  const app = read('app/shell/pubspec.yaml').match(/^version:\s*([^+\s]+)/m)?.[1];
  const settings = read('app/core/lib/features/settings/app_settings_screen.dart')
    .match(/_applicationVersion\s*=\s*'([^']+)'/)?.[1];
  const changelog = read('docs/CHANGELOG.md').match(/^##\s+(\S+)/m)?.[1];
  const whatsNew = read('app/core/lib/features/settings/whats_new_screen.dart');
  const releases = (language) => whatsNew
    .match(new RegExp(`const List<_Release> _${language}Releases[\\s\\S]*?version:\\s*'([^']+)'`))?.[1];
  const versions = {
    'server/package-lock.json': lock.version,
    'server/package-lock.json root package': lock.packages?.['']?.version,
    'app/shell/pubspec.yaml': app,
    'app settings': settings,
    'changelog': changelog,
    'Chinese What\'s new': releases('zh'),
    'English What\'s new': releases('en'),
  };
  if (!/^\d+\.\d+\.\d+$/.test(version || '')) throw new Error('Invalid backend version');
  for (const [name, actual] of Object.entries(versions)) {
    if (actual !== version) throw new Error(`${name}: expected ${version}, got ${actual || 'nothing'}`);
  }
  return version;
}

if (require.main === module) {
  try {
    console.log(`Release versions match: ${checkVersions(path.resolve(__dirname, '../..'))}`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

module.exports = { checkVersions };
