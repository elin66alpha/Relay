import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/platform/platform_capabilities.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/core/theme/app_theme.dart';
import 'package:relay_core/features/ssh/ssh_terminal_controller.dart';
import 'package:relay_core/features/ssh/ssh_terminal_screen.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('SSH terminal uses a mono font stack and follows app themes', (
    WidgetTester tester,
  ) async {
    final SshTerminalController controller = SshTerminalController(
      backend: _FailingBackendClient(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SshTerminalScreen(
            controller: controller,
            machineId: 'machine-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    TerminalView terminalView = tester.widget<TerminalView>(
      find.byType(TerminalView),
    );
    expect(
      terminalView.theme.background,
      AppTheme.light().scaffoldBackgroundColor,
    );
    expect(terminalView.theme.foreground, const Color(0xFF101923));
    expect(
      terminalView.textStyle.fontFamily,
      'packages/relay_core/RelayTerminalMono',
    );
    expect(
      terminalView.textStyle.fontFamilyFallback,
      containsAll(<String>['Cascadia Mono', 'Consolas', 'Menlo', 'monospace']),
    );
    expect(terminalView.textStyle.height, 1.2);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.dark,
          home: SshTerminalScreen(
            controller: controller,
            machineId: 'machine-1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    terminalView = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(
      terminalView.theme.background,
      AppTheme.dark().scaffoldBackgroundColor,
    );
    expect(terminalView.theme.foreground, const Color(0xFFEAF6FF));
    expect(
      terminalView.textStyle.fontFamily,
      'packages/relay_core/RelayTerminalMono',
    );
  });

  testWidgets(
    'SSH terminal shows the modifier key bar only on mobile',
    (WidgetTester tester) async {
      final SshTerminalController controller = SshTerminalController(
        backend: _FailingBackendClient(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        AppScope(
          controller: AppSettingsController(),
          child: MaterialApp(
            theme: AppTheme.light(),
            home: SshTerminalScreen(
              controller: controller,
              machineId: 'machine-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      if (usesHardwareKeyboard) {
        expect(find.text('Ctrl'), findsNothing);
        return;
      }
      for (final String label in <String>['Ctrl', 'Shift', 'Esc', 'Tab']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(controller.ctrlLatched, isTrue);
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(controller.ctrlLatched, isFalse);
    },
    variant: const TargetPlatformVariant(
      <TargetPlatform>{TargetPlatform.android, TargetPlatform.linux},
    ),
  );

  testWidgets('SSH terminal names its view when it attaches text input', (
    WidgetTester tester,
  ) async {
    // The Windows embedder rejects a text input client without a view id,
    // which leaves typed characters nowhere to go while Ctrl keys still work.
    bool attached = false;
    Object? viewId;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (MethodCall call) async {
        if (call.method == 'TextInput.setClient') {
          attached = true;
          viewId = ((call.arguments as List<Object?>).last
              as Map<Object?, Object?>)['viewId'];
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.textInput, null),
    );
    final SshTerminalController controller = SshTerminalController(
      backend: _FailingBackendClient(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          theme: AppTheme.light(),
          home:
              SshTerminalScreen(controller: controller, machineId: 'machine-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(attached, isTrue);
    expect(viewId, tester.view.viewId);
  },
      // Known bug: xterm 4.0.0 sends no view id, so typing is dead on Windows.
      // Unskip once xterm is patched (TerminalStudio/xterm.dart #228, #231).
      skip: true);
}

class _FailingBackendClient extends BackendClient {
  @override
  Future<Uri> terminalWebSocketUri({required int cols, required int rows}) {
    throw BackendException('terminal offline');
  }
}
