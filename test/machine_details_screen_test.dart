import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/models/cli_agent.dart';
import 'package:relay/core/models/machine_credential.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/features/cli_agents/cli_agents_controller.dart';
import 'package:relay/features/machines/machine_details_screen.dart';
import 'package:xterm/xterm.dart';

const MachineCredential _machine = MachineCredential(
  id: 'machine-1',
  name: 'Test machine',
  baseUrl: 'https://relay.example.com',
  token: 'device-token',
  createdAt: '2026-07-13T00:00:00.000Z',
);

Future<void> _pumpDetails(
  WidgetTester tester,
  CliAgentsController agentsController,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final _OfflineBackendClient backend = _OfflineBackendClient();
  addTearDown(backend.close);

  await tester.pumpWidget(
    AppScope(
      controller: AppSettingsController(),
      child: MaterialApp(
        home: MachineDetailsScreen(
          machine: _machine,
          backend: backend,
          agentsController: agentsController,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sections run hardware to status; SSH reuses a terminal', (
    WidgetTester tester,
  ) async {
    await _pumpDetails(tester, CliAgentsController());

    final double ssh = tester.getTopLeft(find.text('Enter SSH')).dy;
    final double machine = tester.getTopLeft(find.text('Test machine')).dy;
    final double agents = tester.getTopLeft(find.text('CLI agents')).dy;
    final double tokens = tester.getTopLeft(find.text('Device tokens')).dy;
    final double status = tester.getTopLeft(find.text('Status')).dy;
    expect(
      ssh < machine && machine < agents && agents < tokens && tokens < status,
      isTrue,
    );
    expect(find.text('Intel Core i7 · 8 threads'), findsOneWidget);
    expect(find.text('NVIDIA GeForce GTX 1060'), findsOneWidget);
    expect(find.text('/  1.0 GB used / 4.0 GB total'), findsOneWidget);
    expect(find.text('Mainboard'), findsOneWidget);
    expect(find.text('49°C'), findsOneWidget);
    expect(
      tester.getSize(find.widgetWithText(FilledButton, 'Enter SSH')).width,
      lessThan(360),
    );

    await tester.tap(find.text('Enter SSH'));
    await tester.pumpAndSettle();
    expect(find.text('SSH terminal'), findsOneWidget);
    final Terminal firstTerminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;

    await tester.tap(find.byTooltip('Back to machine details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter SSH'));
    await tester.pumpAndSettle();
    final Terminal secondTerminal =
        tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    expect(identical(firstTerminal, secondTerminal), isTrue);
  });

  testWidgets('authenticated agents show Ready', (
    WidgetTester tester,
  ) async {
    final CliAgentsController agentsController = CliAgentsController()
      ..syncAgents(<CliAgent>[
        const CliAgent(
          key: 'claude',
          label: 'Claude Code',
          description: 'Anthropic Claude Code CLI',
          authKind: 'oauth',
        ),
        const CliAgent(
          key: 'codex',
          label: 'Codex',
          description: 'OpenAI Codex CLI',
          authKind: 'oauth',
        ),
      ]);

    await _pumpDetails(tester, agentsController);

    expect(find.text('Ready'), findsNWidgets(2));
    expect(find.widgetWithText(FilledButton, 'Log in'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Log in again'), findsNothing);
  });
}

class _OfflineBackendClient extends BackendClient {
  @override
  Future<Uri> terminalWebSocketUri({required int cols, required int rows}) {
    throw BackendException('terminal offline');
  }

  @override
  Future<BackendDiagnostics> diagnostics({
    Duration timeout = const Duration(seconds: 8),
  }) {
    throw BackendException('offline');
  }

  @override
  Future<MachineInfo> machineInfo() async =>
      MachineInfo.fromJson(const <String, Object?>{
        'cpu': <String, Object?>{'model': 'Intel Core i7', 'cores': 8},
        'memoryBytes': 17179869184,
        'gpus': <String>['NVIDIA GeForce GTX 1060'],
        'disks': <Map<String, Object?>>[
          <String, Object?>{
            'mount': '/',
            'usedBytes': 1073741824,
            'totalBytes': 4294967296,
          },
        ],
        'temperatures': <Map<String, Object?>>[
          <String, Object?>{'key': 'mainboard', 'celsius': 29},
          <String, Object?>{'key': 'cpu', 'celsius': 49},
        ],
      });

  @override
  Future<List<DeviceToken>> deviceTokens() async => const <DeviceToken>[];

  @override
  Future<void> close() async {}
}
