import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/models/agent_session.dart';
import 'package:relay_core/core/models/cli_agent.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/features/chat/bot_chat_controller.dart';
import 'package:relay_core/features/quota/quota_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final String code in <String>['CANCEL_FAILED', 'REQUEST_NOT_FOUND']) {
    test('cancellation error $code preserves the running turn', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final _CancelBackend backend = _CancelBackend(code);
      final QuotaController quota = QuotaController(backendClient: backend);
      final BotChatController controller = BotChatController(
        backendClient: backend,
        quotaController: quota,
      );
      addTearDown(controller.disposeController);
      addTearDown(quota.dispose);
      await controller.loadFor(
        defaultCliAgents.first,
        MachineCredential(
          id: 'test-machine',
          name: 'Test machine',
          baseUrl: 'http://127.0.0.1:8787',
          token: 'test-token',
          createdAt: DateTime.utc(2026).toIso8601String(),
        ),
      );

      final Future<void> turn = controller.sendUserText('hello');
      await backend.started.future;
      await controller.cancelActiveTurn();

      expect(controller.isThinking, isTrue);
      final systemMessages =
          controller.messages.where(controller.isSystemMessage);
      if (code == 'REQUEST_NOT_FOUND') {
        expect(systemMessages, isEmpty);
      } else {
        expect(systemMessages.single.content, 'Could not stop the turn');
        expect(controller.isCancelling, isFalse);
      }
      backend.reply.complete(
        ChatReply(
          requestId: backend.requestId!,
          agentKey: 'claude',
          agentLabel: 'Claude Code',
          content: 'Finished normally',
        ),
      );
      await turn;
      expect(controller.isThinking, isFalse);
      expect(controller.messages.any(controller.isCancelled), isFalse);
      expect(
        controller.messages
            .any((message) => message.content == 'Finished normally'),
        isTrue,
      );
    });
  }
}

class _CancelBackend extends BackendClient {
  _CancelBackend(this.errorCode);

  final String errorCode;
  final Completer<void> started = Completer<void>();
  final Completer<ChatReply> reply = Completer<ChatReply>();
  String? requestId;

  @override
  Future<WorkdirInfo> workdir() async => const WorkdirInfo(dir: '/test');

  @override
  Future<Map<String, bool?>> fetchAuthStatus({
    bool verifyCredentials = false,
  }) async =>
      <String, bool?>{};

  @override
  Future<AgentSessionList> fetchSessions(String agentKey) async =>
      AgentSessionList(
        agentKey: agentKey,
        workdir: '/test',
        activeSessionId: 'main',
        sessions: <AgentSession>[
          AgentSession(
            id: 'main',
            name: 'Main',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        ],
      );

  @override
  Future<ChatHistory> fetchHistory(
    String agentKey, {
    required String sessionId,
  }) async =>
      const ChatHistory(messages: []);

  @override
  Future<ChatReply> sendMessage({
    required String agentKey,
    required String sessionId,
    required String prompt,
    required String requestId,
    ChatStreamHandle? streamHandle,
    void Function()? onStreamStarted,
    void Function(BackendEvent)? onEvent,
  }) {
    this.requestId = requestId;
    onStreamStarted?.call();
    started.complete();
    return reply.future;
  }

  @override
  Future<void> cancelMessage(String requestId) async {
    expect(requestId, this.requestId);
    throw BackendException('Could not stop the turn', code: errorCode);
  }
}
