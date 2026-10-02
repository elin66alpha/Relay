import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/models/agent_session.dart';
import 'package:relay/core/models/chat_message.dart';
import 'package:relay/core/models/cli_agent.dart';
import 'package:relay/core/models/machine_credential.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/core/storage/machine_credentials_store.dart';
import 'package:relay/core/theme/app_theme.dart';
import 'package:relay/features/chat/bot_chat_controller.dart';
import 'package:relay/features/chat/bot_chat_screen.dart';
import 'package:relay/features/cli_agents/cli_agents_controller.dart';
import 'package:relay/features/machines/machine_credentials_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _userText = 'Please check the build';

void main() {
  for (final (String name, ThemeData theme) in <(String, ThemeData)>[
    ('light', AppTheme.light()),
    ('dark', AppTheme.dark()),
  ]) {
    testWidgets('a selection in your own bubble is visible ($name)', (
      WidgetTester tester,
    ) async {
      await _openChat(tester, theme);

      final RichText text = tester.widget<RichText>(
        find.byWidgetPredicate(
          (Widget w) =>
              w is RichText && w.text.toPlainText() == _userText,
        ),
      );
      final Color bubble = theme.colorScheme.primary;
      // The default selection colour is the primary colour, which is also the
      // bubble's fill; the bubble must override it with its text colour.
      expect(
        text.selectionColor,
        theme.colorScheme.onPrimary.withValues(alpha: 0.35),
      );
      expect(text.selectionColor!.withValues(alpha: 1), isNot(bubble));
    });
  }
}

Future<void> _openChat(WidgetTester tester, ThemeData theme) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  MachineCredentialsStore.resetCacheForTest();
  final MachineCredential machine = MachineCredential(
    id: 'machine-1',
    name: 'Local test',
    baseUrl: 'http://127.0.0.1:8787',
    token: 'token',
    createdAt: DateTime.utc(2026).toIso8601String(),
  );
  final CliAgentsController agentsController = CliAgentsController();
  final MachineCredentialsController machinesController =
      MachineCredentialsController(store: _MemoryStore(machine));
  final AppSettingsController settingsController = AppSettingsController();
  final BotChatController chatController =
      BotChatController(backendClient: _ChatBackendClient());
  addTearDown(chatController.disposeController);

  await agentsController.load();
  await machinesController.load();
  await chatController.loadFor(defaultCliAgents.first, machine);

  await tester.pumpWidget(
    AppScope(
      controller: settingsController,
      child: MaterialApp(
        theme: theme,
        home: BotChatScreen(
          agentsController: agentsController,
          chatController: chatController,
          machinesController: machinesController,
          settingsController: settingsController,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _MemoryStore extends MachineCredentialsStore {
  _MemoryStore(this.machine);

  final MachineCredential machine;

  @override
  Future<List<MachineCredential>> readAll() async =>
      <MachineCredential>[machine];

  @override
  Future<String?> readActiveId() async => machine.id;

  @override
  Future<void> setActive(String id) async {}

  @override
  Future<void> upsert(
    MachineCredential credential, {
    bool makeActive = true,
  }) async {}

  @override
  Future<void> delete(String id) async {}
}

class _ChatBackendClient extends BackendClient {
  // Stays open: an empty stream would complete and schedule a reconnect timer
  // that outlives the test.
  final StreamController<BackendEvent> _events =
      StreamController<BackendEvent>.broadcast();

  @override
  Stream<BackendEvent> streamEvents() => _events.stream;

  @override
  Future<void> close() async => _events.close();

  @override
  Future<Map<String, bool?>> fetchAuthStatus({
    bool verifyCredentials = false,
  }) async =>
      const <String, bool?>{};

  @override
  Future<List<CliAgent>> fetchAgents({bool verifyCredentials = false}) async =>
      defaultCliAgents;

  @override
  Future<UsageReport> usageReport({String? source}) async =>
      UsageReport.fromJson(const <String, Object?>{});

  @override
  Future<AgentSessionList> fetchSessions(String agentKey) async =>
      AgentSessionList(
        agentKey: agentKey,
        workdir: '/repo',
        activeSessionId: AgentSession.defaultId,
        sessions: <AgentSession>[AgentSession.fallback()],
      );

  @override
  Future<List<ChatMessage>> fetchHistory(
    String agentKey, {
    required String sessionId,
  }) async =>
      <ChatMessage>[
        ChatMessage(
          id: 'user-1',
          role: ChatRole.user,
          content: _userText,
          createdAt: DateTime.utc(2026),
        ),
      ];
}
