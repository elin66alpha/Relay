import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/features/chat/bot_chat_controller.dart';
import 'package:relay_core/features/chat/home_navigation_page.dart';
import 'package:relay_core/features/cli_agents/cli_agents_controller.dart';
import 'package:relay_core/features/machines/machine_credentials_controller.dart';
import 'package:relay_core/features/quota/quota_controller.dart';

void main() {
  testWidgets('recent workdirs cannot cross machines or accept stale responses',
      (tester) async {
    final machines = _Machines();
    final backend = _HomeBackend();
    final chat = BotChatController(
      backendClient: backend,
      quotaController: QuotaController(backendClient: backend),
    );
    final agents = CliAgentsController();
    addTearDown(chat.disposeController);
    addTearDown(machines.dispose);
    addTearDown(agents.dispose);
    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: Scaffold(
            body: HomeNavigationPage(
              chatController: chat,
              agentsController: agents,
              machinesController: machines,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    backend.requests[0].complete(<String>[
      '/a/project',
      '/a/second',
      '/a/third',
      '/a/fourth',
      '/a/fifth',
      '/a/sixth',
    ]);
    await tester.pumpAndSettle();
    for (final dir in <String>[
      'project',
      'second',
      'third',
      'fourth',
      'fifth',
    ]) {
      expect(find.text('/a/$dir'), findsOneWidget);
    }
    expect(find.text('/a/sixth'), findsNothing);
    final oldTile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, '/a/project'),
    );
    expect(oldTile.onTap, isNotNull);

    // Keep a refresh on A pending while switching to B.
    final pendingRefresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, '/a/project'))
          .onTap,
      isNull,
    );
    machines.select('b');
    // Even a callback from the previous frame must not submit A's path to B.
    oldTile.onTap!();
    await tester.pump();
    expect(find.text('/a/project'), findsNothing);
    expect(backend.selected, isEmpty);

    backend.requests[2].complete(<String>['/b/project']);
    await tester.pumpAndSettle();
    backend.requests[1].complete(<String>['/a/stale']);
    await pendingRefresh;
    await tester.pumpAndSettle();
    expect(find.text('/a/stale'), findsNothing);
    expect(find.text('/b/project'), findsOneWidget);

    // The old callback is still invalid after B has finished loading.
    oldTile.onTap!();
    await tester.pump();
    expect(backend.selected, isEmpty);
    await tester.tap(find.text('/b/project'));
    await tester.pump();
    expect(backend.selected, <String>['/b/project']);
    backend.requests.last.complete(<String>['/b/project']);
    await tester.pumpAndSettle();
  });

  testWidgets(
      'workspaces page lists current plus seven recent and switches back to chat',
      (tester) async {
    final backend = _HomeBackend();
    final chat = BotChatController(
      backendClient: backend,
      quotaController: QuotaController(backendClient: backend),
    );
    addTearDown(chat.disposeController);
    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => WorkspacesPage(chatController: chat),
                  ),
                ),
                child: const Text('chat'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('chat'));
    await tester.pump();
    backend.requests.single.complete(<String>[
      '/r1',
      '/current',
      for (int i = 2; i <= 9; i += 1) '/r$i',
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Current workspace'), findsOneWidget);
    expect(find.text('/current'), findsOneWidget);
    for (int i = 1; i <= 7; i += 1) {
      expect(find.text('/r$i'), findsOneWidget);
    }
    expect(find.text('/r8'), findsNothing);
    expect(find.text('File system'), findsOneWidget);

    await tester.tap(find.text('/r3'));
    await tester.pumpAndSettle();
    expect(backend.selected, <String>['/r3']);
    expect(chat.activeWorkdir, '/r3');
    expect(find.byType(WorkspacesPage), findsNothing);
    expect(find.text('Work directory updated.'), findsOneWidget);
  });
}

class _Machines extends MachineCredentialsController {
  String id = 'a';

  @override
  MachineCredential get activeMachine => MachineCredential(
        id: id,
        name: id,
        baseUrl: 'http://localhost',
        token: 'test-token',
        createdAt: '',
      );

  void select(String next) {
    id = next;
    notifyListeners();
  }
}

class _HomeBackend extends BackendClient {
  final requests = <Completer<List<String>>>[];
  final selected = <String>[];

  @override
  Future<bool> health({Duration? timeout}) async => true;

  @override
  Future<WorkdirInfo> workdir() async => const WorkdirInfo(dir: '/current');

  @override
  Future<List<String>> recentWorkdirs() {
    final request = Completer<List<String>>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) async {
    selected.add(path);
    return WorkdirInfo(dir: path);
  }

  @override
  Future<void> close() async {}
}
