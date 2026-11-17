import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/features/settings/app_settings_screen.dart';
import 'package:relay_core/features/settings/app_update.dart';
import 'package:relay_core/features/settings/app_update_io.dart';

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
    expect(
      windowsReplaceScript(
        pid: 42,
        archive: r"C:\Temp\it's\relay.zip",
        executable: r'D:\Apps\Relay\relay.exe',
      ),
      'Wait-Process -Id 42 -ErrorAction SilentlyContinue; '
      r"Expand-Archive -LiteralPath 'C:\Temp\it''s\relay.zip' "
      r"-DestinationPath 'D:\Apps\Relay' -Force; "
      r"Start-Process -FilePath 'D:\Apps\Relay\relay.exe'",
    );
  });

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

  testWidgets('iOS only reports the release', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await check(tester, latest: '0.1.14');
    debugDefaultTargetPlatformOverride = null;

    expect(
      find.text('Version 0.1.14 is available on GitHub Releases'),
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
