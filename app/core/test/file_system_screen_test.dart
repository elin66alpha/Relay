import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/core/widgets/code_block.dart';
import 'package:relay_core/features/chat/bot_chat_controller.dart';
import 'package:relay_core/features/filesystem/file_system_screen.dart';
import 'package:relay_core/features/quota/quota_controller.dart';

void main() {
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
        'large.md': utf8.encode(' ${'你' * (limit ~/ 3 + 1)}'),
      },
    );
    await _openFiles(tester, backend);
    await _openPreview(tester, 'large.md');

    final CodeBlock code = tester.widget<CodeBlock>(find.byType(CodeBlock));
    expect(code.code, ' ${'你' * ((limit - 1) ~/ 3)}');
    expect(find.text('Only the first 512 KiB is shown.'), findsOneWidget);
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
    // compute completes on a real isolate, outside the test's fake clock.
    for (int i = 0;
        i < 100 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

class _FsBackendClient extends BackendClient {
  _FsBackendClient({this.files = const <String, List<int>>{}});

  final Map<String, List<int>> files;
  final List<String> browsed = <String>[];
  final List<String> createdDirs = <String>[];
  int downloadedBytes = 0;
  bool downloadClosed = false;

  @override
  Future<WorkdirInfo> workdir() async => const WorkdirInfo(dir: '/repo/app');

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
    final bool atRoot = path == '/repo';
    final String child = atRoot ? 'app' : 'src';
    return FsListing(
      root: '/',
      path: path,
      absolutePath: path,
      parentPath: atRoot ? null : '/repo',
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
