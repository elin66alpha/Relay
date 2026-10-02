import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/backend/sse_codec.dart';
import 'package:relay/core/models/agent_session.dart';
import 'package:relay/core/models/chat_message.dart';
import 'package:relay/core/models/cli_agent.dart';
import 'package:relay/core/models/machine_credential.dart';
import 'package:relay/core/storage/workdir_store.dart';
import 'package:relay/features/chat/bot_chat_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('setting a new workdir moves the sessions and chat to it', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    WorkdirStore.resetCacheForTest();
    final _WorkdirBackendClient backend = _WorkdirBackendClient();
    final BotChatController controller =
        BotChatController(backendClient: backend);
    addTearDown(controller.disposeController);

    await controller.loadFor(defaultCliAgents.first, _machine);
    // With the live event stream connected, as it is in the app.
    controller.connectEvents();
    await pumpEventQueue();
    expect(controller.activeSession?.name, 'Chat in /a');

    // Completing promptly is the point: the switch used to wait on the idle
    // event stream (up to its 30s heartbeat) before reloading anything.
    await controller.setWorkdir('/b').timeout(const Duration(seconds: 2));

    expect(controller.activeWorkdir, '/b');
    expect(
      controller.sessionsFor('claude').map((AgentSession s) => s.name),
      <String>['Chat in /b'],
    );
    expect(
      controller.messages.map((ChatMessage m) => m.content),
      <String>['hello from /b'],
    );
  });
}

final MachineCredential _machine = MachineCredential(
  id: 'machine-1',
  name: 'Local test',
  baseUrl: 'http://127.0.0.1:8787',
  token: 'token',
  createdAt: DateTime.utc(2026).toIso8601String(),
);

/// A backend whose sessions and history belong to whichever workdir is set.
class _WorkdirBackendClient extends BackendClient {
  String _dir = '/a';
  final List<StreamController<List<int>>> _bodies =
      <StreamController<List<int>>>[];

  // The real event stream: `ready`, then quiet until the next heartbeat.
  @override
  Stream<BackendEvent> streamEvents() {
    final StreamController<List<int>> body = StreamController<List<int>>();
    _bodies.add(body);
    body.add(utf8.encode('event: ready\ndata: {"ok":true}\n\n'));
    return decodeSse(body.stream);
  }

  @override
  Future<void> close() async {
    for (final StreamController<List<int>> body in _bodies) {
      await body.close();
    }
  }

  @override
  Future<Map<String, bool?>> fetchAuthStatus({
    bool verifyCredentials = false,
  }) async =>
      const <String, bool?>{};

  @override
  Future<WorkdirInfo> workdir() async => WorkdirInfo(dir: _dir);

  @override
  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) async {
    _dir = path;
    return WorkdirInfo(dir: path);
  }

  @override
  Future<AgentSessionList> fetchSessions(String agentKey) async {
    return AgentSessionList(
      agentKey: agentKey,
      workdir: _dir,
      activeSessionId: 'session$_dir',
      sessions: <AgentSession>[
        AgentSession(
          id: 'session$_dir',
          name: 'Chat in $_dir',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ],
    );
  }

  @override
  Future<List<ChatMessage>> fetchHistory(
    String agentKey, {
    required String sessionId,
  }) async {
    return <ChatMessage>[
      ChatMessage(
        id: 'message$_dir',
        role: ChatRole.user,
        content: 'hello from $_dir',
        createdAt: DateTime.utc(2026),
      ),
    ];
  }
}
