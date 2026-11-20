import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/features/settings/app_settings_screen.dart';
import 'package:relay_core/features/settings/app_update.dart';
import 'package:relay_core/features/settings/app_update_io.dart';
import 'package:path/path.dart' as p;

void main() {
  test('each platform installs its own release asset', () {
    String? asset(TargetPlatform target) =>
        updateAssetName('0.1.14', target: target, web: false);
    expect(asset(TargetPlatform.android), 'relay-client-android-v0.1.14.apk');
    expect(
      asset(TargetPlatform.windows),
      'relay-client-windows-x64-v0.1.14.zip',
    );
    expect(asset(TargetPlatform.linux), 'relay-client-linux_0.1.14_amd64.deb');
    expect(asset(TargetPlatform.macOS), 'relay-client-macos-v0.1.14.zip');
    expect(asset(TargetPlatform.iOS), isNull);
    expect(
      updateAssetName('0.1.14', target: TargetPlatform.android, web: true),
      isNull,
    );
    expect(
      updateAssetUri('0.1.14', 'relay-client-android-v0.1.14.apk').toString(),
      'https://github.com/elin66alpha/Relay/releases/download/v0.1.14/relay-client-android-v0.1.14.apk',
    );
  });

  test('the Windows replacement waits, unpacks over the app and restarts', () {
    final String script = windowsReplaceScript(
      pid: 42,
      archive: r"C:\Temp\it's\relay.zip",
      executable: r'D:\Apps\Relay\relay.exe',
      log: r'C:\Temp\relay-client-update.log',
    );
    expect(
      script,
      contains('Wait-Process -Id 42 -ErrorAction SilentlyContinue'),
    );
    expect(
      script,
      contains(r'Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Archive"'),
    );
    expect(
      script,
      contains(
        r"Expand-Archive -LiteralPath 'C:\Temp\it''s\relay.zip' "
        r"-DestinationPath 'D:\Apps\Relay' -Force -ErrorAction Stop",
      ),
    );
    expect(
      script,
      contains(r"Out-File -LiteralPath 'C:\Temp\relay-client-update.log'"),
    );
    expect(
      script.trimRight(),
      endsWith(r"Start-Process -FilePath 'D:\Apps\Relay\relay.exe'"),
    );
    // Windows PowerShell does nothing in a process without a console, which
    // is how Dart starts detached programs; `start` gives it its own.
    expect(
      windowsReplaceCommand(r'C:\Temp\relay-client-update.ps1').take(4),
      <String>['/c', 'start', '/min', 'powershell.exe'],
    );
  });

  test(
    'the Windows replacement really replaces the files after the app exits',
    () async {
      final Directory root =
          await Directory.systemTemp.createTemp('relay update ünïcode ');
      addTearDown(() => root.delete(recursive: true));
      final Directory app = await Directory(p.join(root.path, 'app')).create();
      final File version = File(p.join(app.path, 'version.txt'));
      await version.writeAsString('0.2.0');
      // rundll32 without arguments exits at once and shows nothing.
      await File(r'C:\Windows\System32\rundll32.exe')
          .copy(p.join(app.path, 'relay.exe'));
      final Directory release =
          await Directory(p.join(root.path, 'release', 'data')).create(
        recursive: true,
      );
      await File(p.join(release.path, 'asset.txt')).writeAsString('new');
      await File(p.join(release.parent.path, 'version.txt'))
          .writeAsString('0.2.1');
      final String archive = p.join(root.path, 'update.zip');
      final ProcessResult zip = await Process.run('powershell.exe', <String>[
        '-NoProfile',
        '-Command',
        "Compress-Archive -Path '${release.parent.path}\\*' "
            "-DestinationPath '$archive'",
      ]);
      expect(zip.exitCode, 0, reason: '${zip.stderr}');

      // Stands in for the app: the script waits for it to exit.
      final Process running =
          await Process.start('ping.exe', <String>['-n', '3', '127.0.0.1']);
      await startWindowsReplace(
        pid: running.pid,
        archive: archive,
        executable: p.join(app.path, 'relay.exe'),
      );
      await running.exitCode;

      final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
      while (File(archive).existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(File(archive).existsSync(), isFalse, reason: 'ZIP not consumed');
      expect(await version.readAsString(), '0.2.1');
      expect(
        await File(p.join(app.path, 'data', 'asset.txt')).readAsString(),
        'new',
      );
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  Future<void> check(
    WidgetTester tester, {
    required String latest,
    bool silent = false,
  }) async {
    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => checkForAppUpdate(
                  context,
                  silent: silent,
                  currentVersion: '0.1.13',
                  latestVersion: () async => latest,
                ),
                child: const Text('check'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();
  }

  testWidgets('a newer release offers Update and Later', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await check(tester, latest: '0.1.14', silent: true);
    debugDefaultTargetPlatformOverride = null;

    expect(find.text('Version 0.1.14 is available'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.text('Version 0.1.14 is available'), findsNothing);
  });

  testWidgets('iOS points to TestFlight', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await check(tester, latest: '0.1.14');
    debugDefaultTargetPlatformOverride = null;

    expect(
      find.text('Version 0.1.14 is available: update in TestFlight'),
      findsOneWidget,
    );
    expect(find.text('Update'), findsNothing);
  });

  testWidgets('the start-up check stays quiet on the latest version', (
    WidgetTester tester,
  ) async {
    await check(tester, latest: '0.1.13', silent: true);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
