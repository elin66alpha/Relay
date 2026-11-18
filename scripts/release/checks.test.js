'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { checkVersions } = require('./check_versions');
const { checkDocs } = require('./check_docs');

test('release version check catches mismatches in each published version', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-version-check-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const write = (file, text) => {
    const target = path.join(root, file);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, text);
  };
  write('server/package.json', '{"version":"1.2.3"}');
  write('server/package-lock.json', '{"version":"1.2.3","packages":{"":{"version":"1.2.3"}}}');
  write('mcp/package.json', '{"version":"1.2.3"}');
  write('app/shell/pubspec.yaml', 'version: 1.2.3+5\n');
  write('app/core/lib/features/settings/app_settings_screen.dart', "const _applicationVersion = '1.2.3';");
  write('docs/CHANGELOG.md', '## 1.2.3 - today\n');
  const whatsNew = 'app/core/lib/features/settings/whats_new_screen.dart';
  write(whatsNew, "const List<_Release> _zhReleases = [version: '1.2.3'];\nconst List<_Release> _enReleases = [version: '1.2.3'];");
  assert.equal(checkVersions(root), '1.2.3');
  write(whatsNew, "const List<_Release> _zhReleases = [version: '1.2.3'];\nconst List<_Release> _enReleases = [version: '1.2.2'];");
  assert.throws(() => checkVersions(root), /English What's new/);
});

test('documentation check catches missing files and sections', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-doc-check-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'docs'));
  for (const file of ['README.md', 'README.zh-CN.md', 'AGENTS.md', 'ENGINEERING.md']) {
    fs.writeFileSync(path.join(root, file), '');
  }
  fs.writeFileSync(path.join(root, 'docs', 'guide.md'), '# Hello 世界\n');
  fs.writeFileSync(path.join(root, 'README.md'), '[ok](docs/guide.md#hello-世界)\n[bad](docs/guide.md#missing)\n[missing](none.md)\n');
  assert.deepEqual(checkDocs(root), [
    'README.md:2: missing docs/guide.md#missing',
    'README.md:3: missing none.md',
  ]);
});

test('documentation check pairs tutorial articles and resolves their links', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-tutorial-check-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'docs'));
  for (const file of ['README.md', 'README.zh-CN.md', 'AGENTS.md', 'ENGINEERING.md']) {
    fs.writeFileSync(path.join(root, file), '');
  }
  const tutorial = path.join(root, 'app/core/assets/tutorial');
  fs.mkdirSync(path.join(tutorial, 'en'), { recursive: true });
  fs.mkdirSync(path.join(tutorial, 'zh'), { recursive: true });
  fs.writeFileSync(path.join(tutorial, 'en', 'a.md'), '[b](b.md)\n');
  fs.writeFileSync(path.join(tutorial, 'en', 'b.md'), '[gone](gone.md)\n');
  fs.writeFileSync(path.join(tutorial, 'zh', 'a.md'), '[b](b.md)\n');
  assert.deepEqual(checkDocs(root), [
    'app/core/assets/tutorial/zh/b.md: missing translation',
    'app/core/assets/tutorial/en/b.md:1: missing gone.md',
    'app/core/assets/tutorial/zh/a.md:1: missing b.md',
  ]);
});
