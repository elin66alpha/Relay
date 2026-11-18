import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/core/widgets/code_block.dart';
import 'package:relay_core/features/chat/bot_chat_controller.dart';
import 'package:relay_core/features/filesystem/file_system_screen.dart';
import 'package:relay_core/features/quota/quota_controller.dart';

void main() {
  testWidgets('five recent workspaces stay in one compact row on phones',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const paths = <String>[
      '/projects/alpha-workspace',
      r'C:\projects\beta-workspace',
      '/projects/gamma-workspace',
      '/projects/delta-workspace',
      '/projects/epsilon-workspace',
      '/projects/sixth-workspace',
    ];
    const names = <String>[
      'alpha-workspace',
      'beta-workspace',
      'gamma-workspace',
      'delta-workspace',
      'epsilon-workspace',
    ];
    final backend = _FsBackendClient(recentPaths: paths);
    await _openFiles(tester, backend);

    expect(find.text('Recent workspaces'), findsOneWidget);
    final chips = <Finder>[
      for (final name in names) find.widgetWithText(ActionChip, name),
    ];
    final double rowTop = tester.getTopLeft(chips.first).dy;
    for (int i = 0; i < chips.length; i++) {
      expect(chips[i], findsOneWidget);
      expect(find.byTooltip(paths[i]), findsOneWidget);
      expect(tester.getTopLeft(chips[i]).dy, closeTo(rowTop, 0.1));
      expect(tester.getSize(chips[i]).height, lessThanOrEqualTo(48));
      expect(tester.widget<Text>(find.text(names[i])).maxLines, 1);
    }
    expect(find.byTooltip(paths.last), findsNothing);
    expect(find.text('sixth-workspace'), findsNothing);
    expect(
      tester.getBottomLeft(find.text('Recent workspaces')).dy,
      lessThanOrEqualTo(rowTop),
    );
    expect(
      tester.getBottomLeft(chips.first).dy,
      lessThan(tester.getTopLeft(find.text('repo')).dy),
    );

    final row = find.ancestor(
      of: chips.first,
      matching: find.byType(Scrollable),
    );
    await tester.drag(row, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(chips.last.hitTestable(), findsOneWidget);

    await tester.tap(chips.last);
    await tester.pumpAndSettle();
    expect(backend.selectedWorkdirs, <String>[paths[4]]);
    expect(backend.browsed.last, paths[4]);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Set as work path'),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Work path: /repo/app'), findsNothing);

    // Selecting the current workspace again returns from another directory.
    await tester.tap(find.text('..'));
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/repo');
    await tester.tap(chips.last);
    await tester.pumpAndSettle();
    expect(backend.selectedWorkdirs, <String>[paths[4]]);
    expect(backend.browsed.last, paths[4]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recent workspace selection waits for the canonical work path',
      (tester) async {
    final update = Completer<WorkdirInfo>();
    final backend = _FsBackendClient(
      recentPaths: const <String>['/projects/recent'],
      workdirUpdate: update.future,
    );
    await _openFiles(tester, backend);
    final chip = find.widgetWithText(ActionChip, 'recent');
    await tester.tap(chip);
    await tester.pump();
    expect(backend.selectedWorkdirs, <String>['/projects/recent']);
    expect(tester.widget<ActionChip>(chip).onPressed, isNull);
    expect(backend.browsed, <String>['/repo/app']);

    update.complete(const WorkdirInfo(dir: '/canonical/recent'));
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/canonical/recent');
    expect(find.text('Work path'), findsOneWidget);
    expect(find.text('canonical'), findsOneWidget);
    expect(tester.widget<ActionChip>(chip).onPressed, isNotNull);
  });

  testWidgets('failed recent workspace selection keeps the previous work path',
      (tester) async {
    final update = Completer<WorkdirInfo>();
    final backend = _FsBackendClient(
      recentPaths: const <String>['/repo/app', '/projects/recent'],
      workdirUpdate: update.future,
    );
    await _openFiles(tester, backend);
    await tester.tap(find.widgetWithText(ActionChip, 'recent'));
    await tester.pump();
    update.completeError(
      BackendException('busy', code: 'WORKDIR_BUSY'),
    );
    await tester.pumpAndSettle();

    expect(backend.browsed, <String>['/repo/app']);
    expect(
      find.text(const AppStrings(AppLanguage.en).workdirBusy),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.widgetWithText(ActionChip, 'app'),
        matching: find.byIcon(Icons.folder_open_rounded),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ActionChip>(find.widgetWithText(ActionChip, 'recent'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh retries the selected workspace after its browse fails',
      (tester) async {
    final backend = _FsBackendClient(
      recentPaths: const <String>['/projects/recent'],
    );
    await _openFiles(tester, backend);
    backend.failNextBrowse = true;
    await tester.tap(find.widgetWithText(ActionChip, 'recent'));
    await tester.pumpAndSettle();
    expect(backend.selectedWorkdirs, <String>['/projects/recent']);
    expect(find.text('projects'), findsOneWidget);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh_outlined));
    await tester.pumpAndSettle();
    expect(backend.browsed, <String>[
      '/repo/app',
      '/projects/recent',
      '/projects/recent',
    ]);
    expect(find.text('src'), findsOneWidget);
  });

  testWidgets('a pending or failed recent list does not block browsing',
      (tester) async {
    final recent = Completer<List<String>>();
    final backend = _FsBackendClient(recentRequest: recent.future);
    await _openFiles(tester, backend);
    expect(find.text('src'), findsOneWidget);
    await tester.tap(find.text('..'));
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/repo');

    recent.completeError(BackendException('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Recent workspaces'), findsNothing);
    expect(find.text('app'), findsOneWidget);
    await tester.tap(find.text('app'));
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/repo/app');
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh retries a failed initial workdir request',
      (tester) async {
    final backend = _RetryWorkdirBackend();
    await _openFiles(tester, backend);
    expect(backend.browsed, isEmpty);
    final refresh = find.widgetWithIcon(IconButton, Icons.refresh_outlined);
    expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(backend.workdirRequests, 2);
    expect(backend.browsed, <String>['/repo/app']);
    expect(find.text('src'), findsOneWidget);
  });

  test('UNC breadcrumbs keep the server and share together as the root', () {
    expect(
      splitPathBreadcrumbs(r'\\host\share\project\src'),
      <({String label, String path})>[
        (label: r'\\host\share', path: r'\\host\share\'),
        (label: 'project', path: r'\\host\share\project'),
        (label: 'src', path: r'\\host\share\project\src'),
      ],
    );
    for (final root in <String>[r'\\host\share', r'\\host\share\']) {
      expect(splitPathBreadcrumbs(root), <({String label, String path})>[
        (label: r'\\host\share', path: r'\\host\share\'),
      ]);
    }
  });

  testWidgets('set as work path is primary and swiping right goes up a folder',
      (
    WidgetTester tester,
  ) async {
    final _FsBackendClient backend = _FsBackendClient();
    final BotChatController chatController = BotChatController(
      backendClient: backend,
      quotaController: QuotaController(backendClient: backend),
    );
    addTearDown(chatController.disposeController);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: FileSystemScreen(
            backend: backend,
            onSetWorkdir: chatController.setWorkdir,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(FilledButton, 'Set as work path'),
      findsOneWidget,
    );
    expect(find.widgetWithText(OutlinedButton, 'New folder'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Upload file'), findsOneWidget);

    // Creating a new folder refreshes the current directory and shows it.
    await tester.tap(find.widgetWithText(OutlinedButton, 'New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'docs');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(backend.createdDirs, <String>['/repo/app/docs']);
    expect(find.text('docs'), findsOneWidget);

    // A left swipe does nothing; a right swipe opens the parent folder.
    await tester.fling(find.text('src'), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/repo/app');

    await tester.fling(find.text('src'), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/repo');
    expect(find.text('app'), findsOneWidget);

    // Tapping the current work path chip jumps back to /repo/app.
    await tester.tap(find.text('Work path: /repo/app'));
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/repo/app');

    // Tapping ".." in the list goes up to /repo.
    await tester.tap(find.text('..'));
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/repo');

    // Entering app and tapping a breadcrumb segment jumps directly to it.
    await tester.tap(find.text('app'));
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/repo/app');
    await tester.tap(find.text('repo'));
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/repo');
  });

  testWidgets('the first breadcrumb switches between the backend drives', (
    WidgetTester tester,
  ) async {
    Future<_FsBackendClient> open(List<String> drives) async {
      final _FsBackendClient backend = _FsBackendClient(drives: drives);
      await tester.pumpWidget(
        AppScope(
          controller: AppSettingsController(),
          child: MaterialApp(
            key: UniqueKey(),
            home: FileSystemScreen(
              backend: backend,
              onSetWorkdir: backend.setWorkdir,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return backend;
    }

    // An isolated or older backend (no drives) and a host with a single root
    // keep the plain breadcrumb.
    await open(const <String>[]);
    expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
    await open(const <String>['/']);
    expect(find.byIcon(Icons.arrow_drop_down), findsNothing);

    final _FsBackendClient backend =
        await open(const <String>['/', '/Volumes/Backup']);
    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    await tester.tap(find.text('/Volumes/Backup'));
    await tester.pumpAndSettle();
    expect(backend.browsed.last, '/Volumes/Backup');

    await tester.tap(find.widgetWithText(FilledButton, 'Set as work path'));
    await tester.pumpAndSettle();
    expect(backend.selectedWorkdirs.last, '/Volumes/Backup');
  });

  test('FsListing reads drives and tolerates backends without them', () {
    FsListing parse(Object? drives) => FsListing.fromJson(<String, Object?>{
          'absolutePath': r'C:\',
          if (drives != null) 'drives': drives,
        });
    expect(
      parse(<Object?>[r'C:\', r'D:\', 7]).drives,
      <String>[r'C:\', r'D:\'],
    );
    expect(parse(null).drives, isEmpty);
    expect(parse('C:').drives, isEmpty);
  });

  test('splitPathBreadcrumbs parses POSIX and Windows paths', () {
    expect(
      splitPathBreadcrumbs('/repo/app'),
      <({String label, String path})>[
        (label: '/', path: '/'),
        (label: 'repo', path: '/repo'),
        (label: 'app', path: '/repo/app'),
      ],
    );
    expect(
      splitPathBreadcrumbs(r'C:\Users\pc\Relay'),
      <({String label, String path})>[
        (label: 'C:', path: r'C:\'),
        (label: 'Users', path: r'C:\Users'),
        (label: 'pc', path: r'C:\Users\pc'),
        (label: 'Relay', path: r'C:\Users\pc\Relay'),
      ],
    );
  });

  testWidgets('tapping a text file shows selectable contents and download', (
    WidgetTester tester,
  ) async {
    const String content = 'print("你好, Relay")\n';
    final _FsBackendClient backend = _FsBackendClient(
      files: <String, List<int>>{'hello.PY': utf8.encode(content)},
    );
    await _openFiles(tester, backend);
    await _openPreview(tester, 'hello.PY');

    expect(find.widgetWithText(AppBar, 'hello.PY'), findsOneWidget);
    expect(find.text(content, findRichText: true), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(tester.widget<CodeBlock>(find.byType(CodeBlock)).language, 'py');
    expect(find.byTooltip('Download'), findsOneWidget);
  });

  for (final (String kind, List<int> bytes) in <(String, List<int>)>[
    ('NUL byte', <int>[65, 0, 66]),
    ('invalid UTF-8', <int>[0xff, 0xfe]),
  ]) {
    testWidgets('a file with $kind cannot be previewed but can be downloaded', (
      WidgetTester tester,
    ) async {
      final _FsBackendClient backend = _FsBackendClient(
        files: <String, List<int>>{'binary.bin': bytes},
      );
      await _openFiles(tester, backend);
      await _openPreview(tester, 'binary.bin');

      expect(find.text('Cannot preview this file.'), findsOneWidget);
      expect(find.byType(CodeBlock), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.download_outlined),
            )
            .onPressed,
        isNotNull,
      );
    });
  }

  testWidgets('preview stops at 512 KiB and reports truncation', (
    WidgetTester tester,
  ) async {
    const int limit = 512 * 1024;
    final _FsBackendClient backend = _FsBackendClient(
      files: <String, List<int>>{
        'large.txt': List<int>.filled(limit * 2, 32),
      },
    );
    await _openFiles(tester, backend);
    await _openPreview(tester, 'large.txt');

    final CodeBlock code = tester.widget<CodeBlock>(find.byType(CodeBlock));
    expect(code.code.length, limit);
    expect(find.text('Only the first 512 KiB is shown.'), findsOneWidget);
    expect(backend.downloadedBytes, limit);
    expect(backend.downloadClosed, isTrue);
  });

  testWidgets('a cut through a multi-byte character still previews', (
    WidgetTester tester,
  ) async {
    const int limit = 512 * 1024;
    // '你' is 3 bytes; 1 leading space puts a character across the cap.
    final _FsBackendClient backend = _FsBackendClient(
      files: <String, List<int>>{
        'large.utf8.txt': utf8.encode(' ${'你' * (limit ~/ 3 + 1)}'),
      },
    );
    await _openFiles(tester, backend);
    await _openPreview(tester, 'large.utf8.txt');

    final CodeBlock code = tester.widget<CodeBlock>(find.byType(CodeBlock));
    expect(code.code, ' ${'你' * ((limit - 1) ~/ 3)}');
    expect(find.text('Only the first 512 KiB is shown.'), findsOneWidget);
  });

  for (final String fileName in <String>['notes.md', 'README.MARKDOWN']) {
    testWidgets('$fileName defaults to rendered Markdown and toggles to source',
        (
      WidgetTester tester,
    ) async {
      const String markdown = '# Hello Relay\n\n```dart\nvoid main() {}\n```\n';
      final _FsBackendClient backend = _FsBackendClient(
        files: <String, List<int>>{fileName: utf8.encode(markdown)},
      );
      await _openFiles(tester, backend);
      await _openPreview(tester, fileName);

      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(find.text('Hello Relay', findRichText: true), findsOneWidget);
      expect(find.byType(CodeBlock), findsOneWidget);
      expect(tester.widget<CodeBlock>(find.byType(CodeBlock)).language, 'dart');

      await tester.tap(find.byTooltip('View source'));
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownBody), findsNothing);
      final CodeBlock sourceBlock =
          tester.widget<CodeBlock>(find.byType(CodeBlock));
      expect(sourceBlock.code, markdown);

      await tester.tap(find.byTooltip('Rendered preview'));
      await tester.pumpAndSettle();

      expect(find.byType(MarkdownBody), findsOneWidget);
    });
  }

  final img.Image sampleImage = img.Image(width: 4, height: 3);
  for (final (String fileName, Uint8List bytes) in <(String, Uint8List)>[
    ('photo.jpg', img.encodeJpg(sampleImage)),
    ('diagram.png', img.encodePng(sampleImage)),
    ('asset.webp', img.encodeWebP(sampleImage)),
    ('anim.gif', img.encodeGif(sampleImage)),
    ('bitmap.bmp', img.encodeBmp(sampleImage)),
    ('favicon.ico', img.encodeIco(sampleImage)),
  ]) {
    testWidgets('tapping $fileName previews image and enables download', (
      WidgetTester tester,
    ) async {
      final _FsBackendClient backend = _FsBackendClient(
        files: <String, List<int>>{fileName: bytes},
      );
      await _openFiles(tester, backend);
      await _openPreview(tester, fileName);

      expect(find.widgetWithText(AppBar, fileName), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      final Finder image = find.byType(Image);
      expect(image, findsOneWidget);
      expect(find.byType(RawImage), findsOneWidget);
      expect((tester.widget<Image>(image).image as MemoryImage).bytes, bytes);
      expect(find.byType(CodeBlock), findsNothing);
      expect(find.text('Cannot preview this file.'), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.download_outlined),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('image preview streams past 512 KiB without truncation notice', (
    WidgetTester tester,
  ) async {
    final Uint8List largeBmp =
        img.encodeBmp(img.Image(width: 500, height: 400));
    expect(largeBmp.length, greaterThan(512 * 1024));
    final _FsBackendClient backend = _FsBackendClient(
      files: <String, List<int>>{'large.bmp': largeBmp},
    );
    await _openFiles(tester, backend);
    await _openPreview(tester, 'large.bmp');

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Only the first 512 KiB is shown.'), findsNothing);
    expect(backend.downloadedBytes, largeBmp.length);
    expect(backend.downloadClosed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('corrupt image file cannot be previewed but can be downloaded', (
    WidgetTester tester,
  ) async {
    final _FsBackendClient backend = _FsBackendClient(
      files: <String, List<int>>{
        'broken.png': <int>[137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3],
      },
    );
    await _openFiles(tester, backend);
    await _openPreview(tester, 'broken.png');

    expect(find.text('Cannot preview this file.'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(CodeBlock), findsNothing);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.download_outlined),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('text starting with GIF89a without NUL bytes previews as text', (
    WidgetTester tester,
  ) async {
    const String content = 'GIF89a is a format\n';
    final _FsBackendClient backend = _FsBackendClient(
      files: <String, List<int>>{'notes.txt': utf8.encode(content)},
    );
    await _openFiles(tester, backend);
    await _openPreview(tester, 'notes.txt');

    final CodeBlock block = tester.widget<CodeBlock>(find.byType(CodeBlock));
    expect(block.code, content);
    expect(find.byType(Image), findsNothing);
    expect(find.text('Cannot preview this file.'), findsNothing);
  });

  testWidgets('image exceeding pixel cap cannot be previewed', (
    WidgetTester tester,
  ) async {
    final Uint8List hugeBmp =
        Uint8List.fromList(img.encodeBmp(img.Image(width: 4, height: 3)));
    ByteData.sublistView(hugeBmp)
      ..setInt32(18, 10000, Endian.little)
      ..setInt32(22, 5000, Endian.little);
    final _FsBackendClient backend = _FsBackendClient(
      files: <String, List<int>>{'huge.bmp': hugeBmp},
    );
    await _openFiles(tester, backend);
    await _openPreview(tester, 'huge.bmp');

    expect(find.text('Cannot preview this file.'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(CodeBlock), findsNothing);
  });

  for (final String format in <String>['PNG', 'DIB']) {
    testWidgets('ICO with oversized embedded $format cannot be previewed', (
      WidgetTester tester,
    ) async {
      final Uint8List embedded;
      if (format == 'PNG') {
        // A 10000 x 5000 PNG header, with a valid IHDR checksum.
        embedded = Uint8List.fromList(<int>[
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
          0,
          0,
          0,
          13,
          73,
          72,
          68,
          82,
          0,
          0,
          39,
          16,
          0,
          0,
          19,
          136,
          8,
          2,
          0,
          0,
          0,
          152,
          53,
          224,
          31,
          0,
          0,
          0,
          0,
          73,
          69,
          78,
          68,
          174,
          66,
          96,
          130,
        ]);
      } else {
        embedded = Uint8List.sublistView(img.encodeBmp(sampleImage), 14);
        ByteData.sublistView(embedded)
          ..setInt32(4, 10000, Endian.little)
          // ICO stores image height plus its transparency mask height.
          ..setInt32(8, 10000, Endian.little);
      }
      final Uint8List ico = Uint8List(22 + embedded.length);
      ico.setRange(22, ico.length, embedded);
      ByteData.sublistView(ico)
        ..setUint16(2, 1, Endian.little)
        ..setUint16(4, 1, Endian.little)
        ..setUint8(6, 4)
        ..setUint8(7, 3)
        ..setUint16(10, 1, Endian.little)
        ..setUint16(12, 24, Endian.little)
        ..setUint32(14, embedded.length, Endian.little)
        ..setUint32(18, 22, Endian.little);
      final _FsBackendClient backend = _FsBackendClient(
        files: <String, List<int>>{'huge.ico': ico},
      );
      await _openFiles(tester, backend);
      await _openPreview(tester, 'huge.ico');

      expect(find.text('Cannot preview this file.'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.byType(CodeBlock), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Markdown preview shows alt text instead of loading images', (
    WidgetTester tester,
  ) async {
    final _FsBackendClient backend = _FsBackendClient(
      files: <String, List<int>>{
        'images.md': utf8.encode('![logo](https://example.com/a.png)\n'),
      },
    );
    await _openFiles(tester, backend);
    await _openPreview(tester, 'images.md');

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.text('logo'), findsOneWidget);
  });

  testWidgets('large Markdown defaults to source view and can still render', (
    WidgetTester tester,
  ) async {
    final String bigMarkdown =
        '# Title\n\n${'word ' * (maxHighlightedChars ~/ 5 + 1)}';
    final _FsBackendClient backend = _FsBackendClient(
      files: <String, List<int>>{'big.md': utf8.encode(bigMarkdown)},
    );
    await _openFiles(tester, backend);
    await _openPreview(tester, 'big.md');

    expect(find.byType(MarkdownBody), findsNothing);
    expect(tester.widget<CodeBlock>(find.byType(CodeBlock)).code, bigMarkdown);

    await tester.tap(find.byTooltip('Rendered preview'));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownBody), findsOneWidget);
  });
}

Future<void> _openFiles(
  WidgetTester tester,
  _FsBackendClient backend,
) async {
  final BotChatController chatController = BotChatController(
    backendClient: backend,
    quotaController: QuotaController(backendClient: backend),
  );
  addTearDown(chatController.disposeController);
  await tester.pumpWidget(
    AppScope(
      controller: AppSettingsController(),
      child: MaterialApp(
        home: FileSystemScreen(
          backend: backend,
          onSetWorkdir: chatController.setWorkdir,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openPreview(WidgetTester tester, String name) async {
  await tester.tap(find.text(name));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(() async {
    // compute and Image.memory decoding run outside the test's fake clock.
    for (int i = 0;
        i < 100 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
    for (int i = 0;
        i < 50 &&
            find.byType(Image).evaluate().isNotEmpty &&
            find.byType(RawImage).evaluate().isEmpty &&
            find.text('Cannot preview this file.').evaluate().isEmpty;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

class _FsBackendClient extends BackendClient {
  _FsBackendClient({
    this.files = const <String, List<int>>{},
    this.recentPaths = const <String>[],
    this.recentRequest,
    this.workdirUpdate,
    this.drives = const <String>[],
  });

  final Map<String, List<int>> files;
  final List<String> drives;
  final List<String> recentPaths;
  final Future<List<String>>? recentRequest;
  final Future<WorkdirInfo>? workdirUpdate;
  final List<String> selectedWorkdirs = <String>[];
  final List<String> browsed = <String>[];
  final List<String> createdDirs = <String>[];
  bool failNextBrowse = false;
  int downloadedBytes = 0;
  bool downloadClosed = false;

  @override
  Future<WorkdirInfo> workdir() async => const WorkdirInfo(dir: '/repo/app');

  @override
  Future<List<String>> recentWorkdirs() =>
      recentRequest ?? Future<List<String>>.value(recentPaths);

  @override
  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) {
    selectedWorkdirs.add(path);
    return workdirUpdate ?? Future<WorkdirInfo>.value(WorkdirInfo(dir: path));
  }

  @override
  Future<FsEntry> createDirectory({
    required String path,
    required String name,
  }) async {
    final String full = '$path/$name';
    createdDirs.add(full);
    return FsEntry(
      name: name,
      path: full,
      absolutePath: full,
      type: 'directory',
      size: 0,
      modifiedAt: '',
    );
  }

  @override
  Future<FsListing> browseWorkdir(
    String path, {
    bool showHidden = false,
  }) async {
    browsed.add(path);
    if (failNextBrowse) {
      failNextBrowse = false;
      throw BackendException('offline');
    }
    final bool atRoot = path == '/repo';
    final String child = atRoot ? 'app' : 'src';
    return FsListing(
      root: '/',
      path: path,
      absolutePath: path,
      parentPath: atRoot ? null : '/repo',
      drives: drives,
      entries: <FsEntry>[
        FsEntry(
          name: child,
          path: '$path/$child',
          absolutePath: '$path/$child',
          type: 'directory',
          size: 0,
          modifiedAt: '',
        ),
        for (final String dir in createdDirs)
          if (dir.startsWith('$path/'))
            FsEntry(
              name: dir.substring(path.length + 1),
              path: dir,
              absolutePath: dir,
              type: 'directory',
              size: 0,
              modifiedAt: '',
            ),
        for (final MapEntry<String, List<int>> file in files.entries)
          FsEntry(
            name: file.key,
            path: '$path/${file.key}',
            absolutePath: '$path/${file.key}',
            type: 'file',
            size: file.value.length,
            modifiedAt: '',
          ),
      ],
    );
  }

  @override
  Future<FsDownloadStream> openFileDownload(String path) async {
    final String name = path.split('/').last;
    final List<int> bytes = files[name]!;
    return FsDownloadStream(
      fileName: name,
      total: bytes.length,
      bytes: _readFile(bytes),
    );
  }

  Stream<List<int>> _readFile(List<int> bytes) async* {
    try {
      for (int start = 0; start < bytes.length; start += 64 * 1024) {
        final int end = (start + 64 * 1024).clamp(0, bytes.length);
        downloadedBytes += end - start;
        yield bytes.sublist(start, end);
      }
    } finally {
      downloadClosed = true;
    }
  }

  @override
  Future<void> close() async {}
}

class _RetryWorkdirBackend extends _FsBackendClient {
  int workdirRequests = 0;

  @override
  Future<WorkdirInfo> workdir() async {
    if (++workdirRequests == 1) throw BackendException('offline');
    return super.workdir();
  }
}
