import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/backend/sse_codec.dart';
import 'package:relay_core/core/models/agent_session.dart';
import 'package:relay_core/core/models/chat_message.dart';
import 'package:relay_core/core/models/cli_agent.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/features/chat/bot_chat_controller.dart';
import 'package:relay_core/features/quota/quota_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('background turn spinner clears from history when agent_done is missed',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _Backend backend = _Backend();
    final QuotaController quota = QuotaController(backendClient: backend);
    final BotChatController controller = BotChatController(
      backendClient: backend,
      quotaController: quota,
    );
    addTearDown(controller.disposeController);
    addTearDown(quota.dispose);

    await controller.loadFor(defaultCliAgents.first, _machine);
    controller.connectEvents();
    await pumpEventQueue();

    // A turn runs in a session we are not viewing.
    backend.emit('agent_start', 'r1', 'other');
    await pumpEventQueue();
    expect(controller.sessionRunning('claude', 'other'), isTrue);

    // It finishes, but the event stream drops the agent_done edge.
    backend.otherHistory = <ChatMessage>[
      ChatMessage(
        id: 'a1',
        role: ChatRole.assistant,
        content: 'done',
        createdAt: DateTime.utc(2026),
        metadata: <String, Object?>{'requestId': 'r1', 'streaming': false},
      ),
    ];
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(controller.sessionRunning('claude', 'other'), isFalse);
    // The check asks for the newest messages only, not the whole conversation.
    expect(backend.otherTails, allOf(isNotEmpty, everyElement(20)));
  });
}

final MachineCredential _machine = MachineCredential(
  id: 'machine-1',
  name: 'Local test',
  baseUrl: 'http://127.0.0.1:8787',
  token: 'token',
  createdAt: DateTime.utc(2026).toIso8601String(),
);

AgentSession _session(String id) => AgentSession(
      id: id,
      name: id,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

class _Backend extends BackendClient {
  final List<StreamController<List<int>>> _streams =
      <StreamController<List<int>>>[];
  List<ChatMessage> otherHistory = <ChatMessage>[];
  final List<int?> otherTails = <int?>[];

  void emit(String type, String requestId, String sessionId) {
    final String payload = jsonEncode(<String, Object?>{
      'requestId': requestId,
      'agent': <String, Object?>{'key': 'claude', 'label': 'Claude Code'},
      'session': <String, Object?>{'id': sessionId, 'name': sessionId},
    });
    for (final StreamController<List<int>> s in _streams) {
      s.add(utf8.encode('event: $type\ndata: $payload\n\n'));
    }
  }

  @override
  Stream<BackendEvent> streamEvents() {
    final StreamController<List<int>> body = StreamController<List<int>>();
    _streams.add(body);
    body.add(utf8.encode('event: ready\ndata: {"ok":true}\n\n'));
    return decodeSse(body.stream);
  }

  @override
  Future<void> close() async {
    for (final StreamController<List<int>> s in _streams) {
      await s.close();
    }
  }

  @override
  Future<WorkdirInfo> workdir() async => const WorkdirInfo(dir: '/test');

  @override
  Future<Map<String, bool?>> fetchAuthStatus({
    bool verifyCredentials = false,
  }) async =>
      const <String, bool?>{};

  @override
  Future<AgentSessionList> fetchSessions(String agentKey) async =>
      AgentSessionList(
        agentKey: agentKey,
        workdir: '/test',
        activeSessionId: 'main',
        sessions: <AgentSession>[_session('main'), _session('other')],
      );

  @override
  Future<ChatHistory> fetchHistory(
    String agentKey, {
    required String sessionId,
    int? tail,
  }) async {
    if (sessionId != 'other') {
      return const ChatHistory(messages: <ChatMessage>[]);
    }
    otherTails.add(tail);
    return ChatHistory(messages: otherHistory);
  }
}
