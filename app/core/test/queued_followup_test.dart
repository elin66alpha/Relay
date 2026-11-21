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
  test(
      'stale history poll returning while promoted follow-up connects does not drop it',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _QueueBackendClient backend = _QueueBackendClient();
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

    // First turn connects and streams, then its POST stream drops mid-turn so
    // the controller reattaches and begins mirroring from history + events.
    final Completer<ChatReply> firstConnect = Completer<ChatReply>();
    backend.onSend = ({
      required String prompt,
      required String requestId,
      void Function()? onStreamStarted,
    }) {
      onStreamStarted?.call();
      return firstConnect.future;
    };
    final Future<void> firstTurn = controller.sendUserText('first');
    await pumpEventQueue();

    backend.historyMessages = <ChatMessage>[
      ChatMessage(
        id: 'u1',
        role: ChatRole.user,
        content: 'first',
        createdAt: DateTime.utc(2026),
      ),
      ChatMessage(
        id: 'a1',
        role: ChatRole.assistant,
        content: 'partial',
        createdAt: DateTime.utc(2026),
        metadata: <String, Object?>{
          'requestId': backend.lastRequestId!,
          'streaming': true,
        },
      ),
    ];
    firstConnect.completeError(
      BackendException('Lost connection', code: 'STREAM_DISCONNECTED'),
    );
    await firstTurn;
    await pumpEventQueue();

    // Queue a follow-up while the reattached first turn is still running.
    await controller.sendUserText('follow-up');
    expect(controller.messages.last.content, 'follow-up');
    expect(controller.isQueued(controller.messages.last), isTrue);

    // Prepare the follow-up's POST /api/chat so it stays in the pre-headers
    // state (_foregroundTurn != null, _localStreamActive == false) when started.
    final Completer<ChatReply> secondSend = Completer<ChatReply>();
    final Completer<void> secondSent = Completer<void>();
    backend.onSend = ({
      required String prompt,
      required String requestId,
      void Function()? onStreamStarted,
    }) {
      secondSent.complete();
      return secondSend.future;
    };

    // Simulate a lagging history poll already in flight before the first turn
    // finalized, plus an agent_done event that triggers _endRemoteMirror's
    // refresh -> _finishReattachIfNotStreaming -> _maybeDrainQueue().
    final Completer<ChatHistory> stalePoll = Completer<ChatHistory>();
    final List<ChatMessage> finishedTurnOneHistory = <ChatMessage>[
      ChatMessage(
        id: 'u1',
        role: ChatRole.user,
        content: 'first',
        createdAt: DateTime.utc(2026),
      ),
      ChatMessage(
        id: 'a1',
        role: ChatRole.assistant,
        content: 'done',
        createdAt: DateTime.utc(2026),
        metadata: <String, Object?>{
          'requestId': backend.firstRequestId!,
          'streaming': false,
        },
      ),
    ];
    backend.pendingHistoryQueue.add(stalePoll);
    backend.historyMessages = finishedTurnOneHistory;

    // Fire a poll (queued on stalePoll) and then deliver agent_done, whose own
    // _refreshHistorySnapshot completes immediately with finishedTurnOneHistory
    // and drains 'follow-up' into _runTurn (still before HTTP headers arrive).
    backend.emitScopeEvent('agent_done', backend.firstRequestId!);
    await secondSent.future;
    expect(controller.isThinking, isTrue);
    expect(
      controller.messages.any((ChatMessage m) => m.content == 'follow-up'),
      isTrue,
    );

    // Now the stale poll from before 'follow-up' started finally returns.
    stalePoll.complete(ChatHistory(messages: finishedTurnOneHistory));
    await pumpEventQueue();

    // The promoted follow-up and its awaiting assistant bubble must stay intact.
    expect(
      controller.messages.any((ChatMessage m) => m.content == 'follow-up'),
      isTrue,
    );
    expect(controller.isThinking, isTrue);

    final List<ChatMessage> turnTwoHistory = <ChatMessage>[
      ...finishedTurnOneHistory,
      ChatMessage(
        id: 'u2',
        role: ChatRole.user,
        content: 'follow-up',
        createdAt: DateTime.utc(2026),
      ),
      ChatMessage(
        id: 'a2',
        role: ChatRole.assistant,
        content: 'second reply',
        createdAt: DateTime.utc(2026),
        metadata: <String, Object?>{
          'requestId': backend.lastRequestId!,
          'streaming': false,
        },
      ),
    ];
    backend.historyMessages = turnTwoHistory;
    secondSend.complete(
      ChatReply(
        requestId: backend.lastRequestId!,
        agentKey: 'claude',
        agentLabel: 'Claude Code',
        content: 'second reply',
      ),
    );
    await pumpEventQueue();
    expect(
      controller.messages.map((ChatMessage m) => m.content),
      <String>['first', 'done', 'follow-up', 'second reply'],
    );
  });

  test(
      'queued follow-up keeps its bubble if delivery fails before stream starts',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _QueueBackendClient backend = _QueueBackendClient();
    final QuotaController quota = QuotaController(backendClient: backend);
    final BotChatController controller = BotChatController(
      backendClient: backend,
      quotaController: quota,
    );
    addTearDown(controller.disposeController);
    addTearDown(quota.dispose);

    await controller.loadFor(defaultCliAgents.first, _machine);
    await pumpEventQueue();

    final Completer<ChatReply> firstReply = Completer<ChatReply>();
    backend.onSend = ({
      required String prompt,
      required String requestId,
      void Function()? onStreamStarted,
    }) {
      onStreamStarted?.call();
      return firstReply.future;
    };
    final Future<void> firstTurn = controller.sendUserText('first');
    await pumpEventQueue();

    await controller.sendUserText('follow-up');
    expect(controller.isQueued(controller.messages.last), isTrue);

    // When the follow-up drains, simulate a connection failure before headers
    // arrive (!turn.started).
    backend.onSend = ({
      required String prompt,
      required String requestId,
      void Function()? onStreamStarted,
    }) {
      return Future<ChatReply>.error(
        BackendException('Lost connection', code: 'STREAM_DISCONNECTED'),
      );
    };
    backend.historyMessages = <ChatMessage>[
      ChatMessage(
        id: 'u1',
        role: ChatRole.user,
        content: 'first',
        createdAt: DateTime.utc(2026),
      ),
      ChatMessage(
        id: 'a1',
        role: ChatRole.assistant,
        content: 'first reply',
        createdAt: DateTime.utc(2026),
      ),
    ];
    firstReply.complete(
      ChatReply(
        requestId: backend.firstRequestId!,
        agentKey: 'claude',
        agentLabel: 'Claude Code',
        content: 'first reply',
      ),
    );
    await firstTurn;
    await pumpEventQueue();

    final ChatMessage failed = controller.messages.last;
    expect(failed.content, 'follow-up');
    expect(controller.isRetryable(failed), isTrue);
  });

  test('onAppResumed drains queued follow-ups after a finished turn catches up',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _QueueBackendClient backend = _QueueBackendClient();
    final QuotaController quota = QuotaController(backendClient: backend);
    final BotChatController controller = BotChatController(
      backendClient: backend,
      quotaController: quota,
    );
    addTearDown(controller.disposeController);
    addTearDown(quota.dispose);

    // Load a session whose active turn is still streaming on the host.
    backend.historyMessages = <ChatMessage>[
      ChatMessage(
        id: 'u1',
        role: ChatRole.user,
        content: 'first',
        createdAt: DateTime.utc(2026),
      ),
      ChatMessage(
        id: 'a1',
        role: ChatRole.assistant,
        content: 'working...',
        createdAt: DateTime.utc(2026),
        metadata: const <String, Object?>{
          'requestId': 'claude.1',
          'streaming': true,
        },
      ),
    ];
    await controller.loadFor(defaultCliAgents.first, _machine);
    expect(controller.isThinking, isTrue);

    await controller.sendUserText('queued while busy');
    expect(controller.isQueued(controller.messages.last), isTrue);

    // Turn 1 finished while the app was suspended; onAppResumed pulls history
    // and must immediately promote and send the queued follow-up.
    backend.historyMessages = <ChatMessage>[
      ChatMessage(
        id: 'u1',
        role: ChatRole.user,
        content: 'first',
        createdAt: DateTime.utc(2026),
      ),
      ChatMessage(
        id: 'a1',
        role: ChatRole.assistant,
        content: 'first reply',
        createdAt: DateTime.utc(2026),
        metadata: const <String, Object?>{
          'requestId': 'claude.1',
          'streaming': false,
        },
      ),
    ];
    final List<String> sentPrompts = <String>[];
    backend.onSend = ({
      required String prompt,
      required String requestId,
      void Function()? onStreamStarted,
    }) async {
      sentPrompts.add(prompt);
      onStreamStarted?.call();
      backend.historyMessages = <ChatMessage>[
        ...backend.historyMessages,
        ChatMessage(
          id: 'u2',
          role: ChatRole.user,
          content: prompt,
          createdAt: DateTime.utc(2026),
        ),
        ChatMessage(
          id: 'a2',
          role: ChatRole.assistant,
          content: 'second reply',
          createdAt: DateTime.utc(2026),
          metadata: <String, Object?>{
            'requestId': requestId,
            'streaming': false,
          },
        ),
      ];
      return ChatReply(
        requestId: requestId,
        agentKey: 'claude',
        agentLabel: 'Claude Code',
        content: 'second reply',
      );
    };

    await controller.onAppResumed();
    await pumpEventQueue();

    expect(sentPrompts, <String>['queued while busy']);
    expect(
      controller.messages.map((ChatMessage m) => m.content),
      <String>['first', 'first reply', 'queued while busy', 'second reply'],
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

class _QueueBackendClient extends BackendClient {
  final List<StreamController<List<int>>> _eventStreams =
      <StreamController<List<int>>>[];
  final List<Completer<ChatHistory>> pendingHistoryQueue =
      <Completer<ChatHistory>>[];
  List<ChatMessage> historyMessages = <ChatMessage>[];
  String? firstRequestId;
  String? lastRequestId;
  Future<ChatReply> Function({
    required String prompt,
    required String requestId,
    void Function()? onStreamStarted,
  })? onSend;

  void emitScopeEvent(String type, String requestId) {
    final String payload = jsonEncode(<String, Object?>{
      'requestId': requestId,
      'agent': <String, Object?>{'key': 'claude', 'label': 'Claude Code'},
      'session': <String, Object?>{'id': 'main', 'name': 'Main'},
    });
    for (final StreamController<List<int>> stream in _eventStreams) {
      stream.add(utf8.encode('event: $type\ndata: $payload\n\n'));
    }
  }

  @override
  Stream<BackendEvent> streamEvents() {
    final StreamController<List<int>> body = StreamController<List<int>>();
    _eventStreams.add(body);
    body.add(utf8.encode('event: ready\ndata: {"ok":true}\n\n'));
    return decodeSse(body.stream);
  }

  @override
  Future<void> close() async {
    for (final StreamController<List<int>> stream in _eventStreams) {
      await stream.close();
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
  }) {
    if (pendingHistoryQueue.isNotEmpty) {
      return pendingHistoryQueue.removeAt(0).future;
    }
    return Future<ChatHistory>.value(ChatHistory(messages: historyMessages));
  }

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
    firstRequestId ??= requestId;
    lastRequestId = requestId;
    return onSend!(
      prompt: prompt,
      requestId: requestId,
      onStreamStarted: onStreamStarted,
    );
  }
}
