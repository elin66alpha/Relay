import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/features/chat/chat_content.dart';
import 'package:relay_core/features/chat/chat_links.dart';
import 'package:relay_core/features/filesystem/file_system_screen.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

void main() {
  group('classifyChatLink', () {
    String? pathOf(String href) => classifyChatLink(href)?.path;
    String? webOf(String href) => classifyChatLink(href)?.web?.toString();

    test('web addresses', () {
      expect(webOf('https://example.com/a?b=1'), 'https://example.com/a?b=1');
      expect(webOf('HTTP://example.com'), 'http://example.com');
      expect(webOf('mailto:a@example.com'), 'mailto:a@example.com');
      expect(classifyChatLink('https://'), isNull);
    });

    test('backend paths, with line suffixes and encoding removed', () {
      expect(pathOf('lib/main.dart'), 'lib/main.dart');
      expect(pathOf('lib/main.dart:42'), 'lib/main.dart');
      expect(pathOf('notes.md:42:5'), 'notes.md');
      expect(pathOf('/repo/a.dart#L4-L9'), '/repo/a.dart');
      expect(pathOf('docs/my%20notes.md'), 'docs/my notes.md');
      expect(pathOf('file:///repo/a.md'), '/repo/a.md');
      expect(pathOf(r'C:\work\a.md'), r'C:\work\a.md');
      expect(pathOf('file:///C:/work/a.md'), r'C:\work\a.md');
      expect(pathOf(r'\\server\share\a.md'), r'\\server\share\a.md');
    });

    test('anchors, empty targets and other schemes are ignored', () {
      expect(classifyChatLink(''), isNull);
      expect(classifyChatLink('#usage'), isNull);
      expect(classifyChatLink('javascript:alert(1)'), isNull);
      expect(classifyChatLink('data:text/html,hi'), isNull);
      expect(classifyChatLink('intent://scan#Intent;end'), isNull);
    });

    test('file URIs accept localhost and ignore query and line fragments', () {
      expect(pathOf('file://localhost/repo/a.md'), '/repo/a.md');
      expect(pathOf('file:///repo/a.md?x=1'), '/repo/a.md');
      expect(
        pathOf('file://localhost/repo/my%20notes.md?x=1#L3'),
        '/repo/my notes.md',
      );
      expect(pathOf('file:///C:/work/a.md#L4'), r'C:\work\a.md');
      expect(classifyChatLink('file://other/repo/a.md'), isNull);
      expect(classifyChatLink('file:///C:/work/a%3Fb.md'), isNull);
    });
  });

  testWidgets('a tapped Markdown link reports its raw target', (
    WidgetTester tester,
  ) async {
    final List<String> tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: MessageText(
              text: '[notes](docs/notes.md:3)',
              color: Colors.black,
              formatInlineEmphasis: true,
              onTapLink: tapped.add,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('notes', findRichText: true));
    expect(tapped, <String>['docs/notes.md:3']);
  });

  testWidgets('relative file link opens the preview of the workdir file', (
    WidgetTester tester,
  ) async {
    final _LinkBackend backend = _LinkBackend();
    await _pumpLink(tester, backend, 'docs/notes.md:3');

    expect(backend.browsed, <String>['/repo/docs']);
    final FilePreviewScreen preview =
        tester.widget<FilePreviewScreen>(find.byType(FilePreviewScreen));
    expect(preview.entry.path, '/repo/docs/notes.md');
  });

  testWidgets('directory link opens the file browser there', (
    WidgetTester tester,
  ) async {
    final _LinkBackend backend = _LinkBackend();
    await _pumpLink(tester, backend, '/repo/docs/guides');

    final FileSystemScreen browser =
        tester.widget<FileSystemScreen>(find.byType(FileSystemScreen));
    expect(browser.initialPath, '/repo/docs/guides');
    expect(backend.browsed.last, '/repo/docs/guides');
  });

  testWidgets('missing file link explains instead of navigating', (
    WidgetTester tester,
  ) async {
    final _LinkBackend backend = _LinkBackend();
    await _pumpLink(tester, backend, 'docs/missing.md');

    expect(find.byType(FilePreviewScreen), findsNothing);
    expect(
      find.text('The file does not exist or is not accessible.'),
      findsOneWidget,
    );
  });

  testWidgets('web link opens only after confirming the full address', (
    WidgetTester tester,
  ) async {
    final _FakeLauncher launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
    final _LinkBackend backend = _LinkBackend();
    const String url = 'https://example.com/docs?page=2';

    await _pumpLink(tester, backend, url);
    expect(find.text('Open in browser?'), findsOneWidget);
    expect(find.text(url), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(launcher.launched, isEmpty);

    await tester.tap(find.text('link'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(launcher.launched, <String>[url]);
    expect(backend.browsed, isEmpty);
  });
}

Future<void> _pumpLink(
  WidgetTester tester,
  _LinkBackend backend,
  String href,
) async {
  await tester.pumpWidget(
    AppScope(
      controller: AppSettingsController(),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => openChatLink(
                context,
                href: href,
                backend: backend,
                workdir: '/repo',
                onSetWorkdir: (String path) async => WorkdirInfo(dir: path),
              ),
              child: const Text('link'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('link'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(() async {
    // The preview decodes on a real isolate, outside the test's fake clock.
    for (int i = 0;
        i < 100 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

FsEntry _entry(String path, String type) => FsEntry(
      name: path.split('/').last,
      path: path,
      absolutePath: path,
      type: type,
      size: 7,
      modifiedAt: '',
    );

class _LinkBackend extends BackendClient {
  final List<String> browsed = <String>[];

  @override
  Future<WorkdirInfo> workdir() async => const WorkdirInfo(dir: '/repo');

  @override
  Future<FsListing> browseWorkdir(
    String path, {
    bool showHidden = false,
  }) async {
    browsed.add(path);
    return FsListing(
      root: '/',
      path: path,
      absolutePath: path,
      parentPath: '/repo',
      entries: path == '/repo/docs'
          ? <FsEntry>[
              _entry('/repo/docs/notes.md', 'file'),
              _entry('/repo/docs/guides', 'directory'),
            ]
          : const <FsEntry>[],
    );
  }

  @override
  Future<FsDownloadStream> openFileDownload(String path) async {
    final List<int> bytes = utf8.encode('# Notes');
    return FsDownloadStream(
      fileName: path.split('/').last,
      total: bytes.length,
      bytes: Stream<List<int>>.value(bytes),
    );
  }

  @override
  Future<void> close() async {}
}

class _FakeLauncher extends UrlLauncherPlatform {
  final List<String> launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}
