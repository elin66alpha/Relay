import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/models/agent_session.dart';
import 'package:relay_core/core/models/chat_message.dart';
import 'package:relay_core/core/models/cli_agent.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/features/chat/bot_chat_controller.dart';
import 'package:relay_core/features/quota/quota_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('messages with only thinking and tool calls add no blank lines',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _StreamBackend backend = _StreamBackend();
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
    Future<ChatMessage> emit(String type, [String? text]) async {
      backend.onEvent!(
        BackendEvent(
          type: type,
          data: <String, Object?>{
            'requestId': backend.requestId,
            if (text != null) 'text': text,
          },
        ),
      );
      // Streaming updates are flushed on an 80 ms throttle.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return controller.messages.last;
    }

    await emit('agent_delta', 'Looking first.');
    // Three messages that only think and call tools.
    await emit('agent_segment');
    await emit('agent_segment');
    final ChatMessage thinking = await emit('agent_segment');
    expect(thinking.content, 'Looking first.');

    final ChatMessage answered = await emit('agent_delta', 'Done.');
    expect(answered.content, 'Looking first.\n\nDone.');
    expect(
      answered.segments.map((MessageSegment s) => s.text),
      <String>['Looking first.', 'Done.'],
    );

    backend.reply.complete(
      ChatReply(
        requestId: backend.requestId!,
        agentKey: 'claude',
        agentLabel: 'Claude Code',
        content: 'Looking first.\n\nDone.',
      ),
    );
    await turn;
  });
}

class _StreamBackend extends BackendClient {
  final Completer<void> started = Completer<void>();
  final Completer<ChatReply> reply = Completer<ChatReply>();
  String? requestId;
  void Function(BackendEvent)? onEvent;

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
    int? tail,
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
    this.onEvent = onEvent;
    onStreamStarted?.call();
    started.complete();
    return reply.future;
  }
}
