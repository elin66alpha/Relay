import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/models/chat_message.dart';
import 'package:relay_core/core/models/group.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/features/chat/group_chat_controller.dart';

void main() {
  late _GroupBackendClient backend;
  late GroupChatController controller;

  setUp(() {
    backend = _GroupBackendClient();
    controller = GroupChatController(backendClient: backend);
    addTearDown(controller.dispose);
  });

  test('loads the requested swarm and history from the current workspace',
      () async {
    await controller.start(initialGroupId: 'reviewers');

    expect(backend.groupWorkdirs, <String>['/work/a']);
    expect(backend.historyRequests, <String>['/work/a:reviewers']);
    expect(controller.selected?.id, 'reviewers');
    expect(controller.messages.single.content, 'History for /work/a:reviewers');

    await controller.selectGroup(_builders);
    expect(controller.messages.single.content, 'History for /work/a:builders');

    backend.activeWorkdir = '/work/b';
    await controller.loadGroups();
    expect(backend.groupWorkdirs, <String>['/work/a', '/work/b']);
    expect(backend.historyRequests.last, '/work/b:other');
    expect(controller.selected?.id, 'other');
    expect(controller.messages.single.content, 'History for /work/b:other');
  });

  test('sends one human message and shows each reply once its member finishes',
      () async {
    backend.history['builders'] = <ChatMessage>[];
    await controller.start();

    final Future<bool> sending = controller.send('  @claude review this  ');
    final Map<String, String> request = backend.sent.single;
    final String requestId = request['requestId']!;
    expect(request, <String, String>{
      'groupId': 'builders',
      'prompt': '@claude review this',
      'requestId': requestId,
    });
    expect(requestId, isNotEmpty);
    expect(controller.sending, isTrue);
    expect(controller.messages.single.id, '$requestId:human');
    expect(controller.messages.single.role, ChatRole.user);
    expect(controller.messages.single.content, '@claude review this');
    expect(await controller.send('another message'), isFalse);
    expect(backend.sent, hasLength(1));

    final ChatMessage human =
        _message('$requestId:human', '@claude review this');
    backend.emit('group_message', <String, Object?>{'message': human.toJson()});
    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.createdAt, human.createdAt);

    final String memberRequestId = '$requestId:claude';
    final Map<String, Object?> member = <String, Object?>{
      'requestId': memberRequestId,
      'agent': <String, Object?>{'key': 'claude', 'label': 'Reviewer'},
    };
    backend.emit('agent_start', member);
    expect(controller.messages.last.metadata['awaitingFirstToken'], isTrue);
    expect(controller.messages.last.metadata['author'], 'claude');
    expect(controller.messages.last.metadata['agentLabel'], 'Reviewer');

    // Replies are not streamed: partial text never reaches the bubble.
    backend
        .emit('agent_delta', <String, Object?>{...member, 'text': 'Checking'});
    backend.emit('agent_segment', member);
    expect(controller.messages.last.content, isEmpty);
    expect(controller.messages.last.metadata['awaitingFirstToken'], isTrue);

    final ChatMessage reply = _message(
      memberRequestId,
      'Saved reply',
      role: ChatRole.assistant,
    );
    backend.history['builders'] = <ChatMessage>[human, reply];
    backend.running = requestId;
    backend.emit('agent_done', member);
    await pumpEventQueue();
    expect(controller.messages, <ChatMessage>[human, reply]);
    expect(controller.sending, isTrue);

    backend.running = null;
    backend.round.complete();
    expect(await sending, isTrue);
    expect(controller.sending, isFalse);
    expect(controller.messages, <ChatMessage>[human, reply]);
    expect(backend.historyRequests, <String>[
      '/work/a:builders',
      '/work/a:builders',
      '/work/a:builders',
    ]);
  });

  test('ignores other swarms and reloads a round finished on another device',
      () async {
    backend.history['builders'] = <ChatMessage>[];
    await controller.start();

    backend.emit('group_message', <String, Object?>{
      'groupId': 'reviewers',
      'message': _message('other-human', 'Other swarm').toJson(),
    });
    backend.emit('agent_delta', <String, Object?>{
      'groupId': 'reviewers',
      'requestId': 'other-agent',
      'text': 'Other reply',
    });
    backend.emit('group_done', <String, Object?>{
      'groupId': 'reviewers',
      'requestId': 'other-round',
    });
    expect(controller.messages, isEmpty);
    expect(backend.historyRequests, hasLength(1));

    final ChatMessage remote = _message('remote-human', 'From another device');
    backend
        .emit('group_message', <String, Object?>{'message': remote.toJson()});
    expect(controller.messages.single.content, 'From another device');
    final ChatMessage reply = _message(
      'remote-reply',
      'Finished remotely',
      role: ChatRole.assistant,
    );
    backend.history['builders'] = <ChatMessage>[remote, reply];
    backend.emit('group_done', <String, Object?>{'requestId': 'remote-round'});
    await pumpEventQueue();
    expect(controller.messages, <ChatMessage>[remote, reply]);
    expect(backend.historyRequests, hasLength(2));
  });

  test('cancels the running round and keeps its partial reply without an error',
      () async {
    backend.history['builders'] = <ChatMessage>[];
    await controller.start();
    await controller.cancel();
    expect(backend.cancelled, isEmpty);

    final Future<bool> sending = controller.send('@claude start');
    final String requestId = backend.sent.single['requestId']!;
    final String memberRequestId = '$requestId:claude';
    backend.emit('agent_start', <String, Object?>{
      'requestId': memberRequestId,
      'agent': <String, Object?>{'key': 'claude', 'label': 'Claude Code'},
    });
    await controller.cancel();
    expect(backend.cancelled, <String>[requestId]);

    backend.history['builders'] = <ChatMessage>[
      ChatMessage(
        id: memberRequestId,
        role: ChatRole.assistant,
        content: 'Partial reply',
        createdAt: DateTime.utc(2026, 1, 2),
        metadata: const <String, Object?>{'cancelled': true},
      ),
    ];
    backend.emit('agent_cancelled', <String, Object?>{
      'requestId': memberRequestId,
    });
    await pumpEventQueue();
    expect(controller.messages.last.content, 'Partial reply');
    expect(controller.messages.last.metadata['cancelled'], isTrue);
    backend.round.completeError(
      BackendException('request cancelled', code: 'AGENT_CANCELLED'),
    );

    expect(await sending, isTrue);
    expect(controller.sending, isFalse);
    expect(controller.error, isNull);
    expect(controller.messages.last.content, 'Partial reply');
    expect(backend.historyRequests, hasLength(3));
  });

  test('a dropped request keeps a round the backend recorded as running',
      () async {
    backend.history['builders'] = <ChatMessage>[];
    await controller.start();

    final Future<bool> sending = controller.send('@claude long task');
    final String requestId = backend.sent.single['requestId']!;
    backend.history['builders'] = <ChatMessage>[
      _message('$requestId:human', '@claude long task'),
    ];
    backend.running = requestId;
    backend.round.completeError(
      BackendException('Timed out.', code: 'NETWORK_TIMEOUT'),
    );

    expect(await sending, isTrue);
    expect(controller.error, isNull);
    expect(controller.sending, isTrue);
    await controller.cancel();
    expect(backend.cancelled, <String>[requestId]);
  });

  test('a dropped request the backend never recorded is an error', () async {
    backend.history['builders'] = <ChatMessage>[];
    await controller.start();

    final Future<bool> sending = controller.send('@claude hello');
    backend.round.completeError(
      BackendException(
        'Connection refused.',
        code: 'NETWORK_CONNECTION_REFUSED',
      ),
    );

    expect(await sending, isFalse);
    expect(controller.error, isNotNull);
    expect(controller.sending, isFalse);
  });

  testWidgets('a reconnected event stream reloads the open swarm',
      (WidgetTester tester) async {
    backend.history['builders'] = <ChatMessage>[];
    backend.running = 'other-device-round';
    await controller.start();
    expect(controller.sending, isTrue);

    // The round ends while the stream is down, so its group_done is lost.
    backend.dropEvents();
    final ChatMessage reply = _message(
      'other-device-reply',
      'Done elsewhere',
      role: ChatRole.assistant,
    );
    backend.history['builders'] = <ChatMessage>[reply];
    backend.running = null;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(controller.sending, isFalse);
    expect(controller.messages, <ChatMessage>[reply]);
  });

  test('a round carries only the credentials of its members\' machines',
      () async {
    const MachineCredential studio = MachineCredential(
      id: 'studio',
      name: 'Studio',
      baseUrl: 'http://10.0.0.5:8787/',
      token: 'studio-token',
      createdAt: '',
    );
    const MachineCredential laptop = MachineCredential(
      id: 'laptop',
      name: 'Laptop',
      baseUrl: 'http://10.0.0.6:8787',
      token: 'laptop-token',
      createdAt: '',
    );
    final GroupChatController linked = GroupChatController(
      backendClient: backend,
      machines: () => const <MachineCredential>[studio, laptop],
    );
    addTearDown(linked.dispose);
    backend.history['mixed'] = <ChatMessage>[];
    await linked.start(initialGroupId: 'mixed');

    expect(linked.isMemberLinked('claude'), isTrue);
    expect(linked.isMemberLinked('4e7eeaf61885:claude'), isTrue);
    expect(linked.isMemberLinked('0123456789ab:codex'), isFalse);

    final Future<bool> sending = linked.send('@4e7eeaf61885:claude go');
    expect(backend.sentPeers.single, <MachineCredential>[studio]);
    backend.round.complete();
    expect(await sending, isTrue);
  });

  test('reopening a swarm with a running round keeps Stop until it ends',
      () async {
    backend.history['builders'] = <ChatMessage>[];
    backend.running = 'round-1';
    await controller.start();

    expect(controller.sending, isTrue);
    expect(await controller.send('@claude again'), isFalse);
    expect(backend.sent, isEmpty);
    await controller.cancel();
    expect(backend.cancelled, <String>['round-1']);

    backend.running = null;
    backend.emit('group_done', <String, Object?>{'requestId': 'round-1'});
    await pumpEventQueue();
    expect(controller.sending, isFalse);
  });

  test('running state and Stop are tracked independently per swarm', () async {
    backend.history['builders'] = <ChatMessage>[];
    backend.history['reviewers'] = <ChatMessage>[];
    await controller.start();

    // Start a round in builders (A).
    final Completer<void> roundA = Completer<void>();
    final Completer<void> roundB = Completer<void>();
    backend.roundsByGroup['builders'] = roundA;
    backend.roundsByGroup['reviewers'] = roundB;

    final Future<bool> sendA = controller.send('@claude work in A');
    final String reqA = backend.sent.last['requestId']!;
    expect(reqA, isNotEmpty);
    expect(controller.sending, isTrue);

    // Switch to reviewers (B): B is NOT sending and accepts a concurrent round.
    await controller.selectGroup(_reviewers);
    expect(controller.sending, isFalse);
    final Future<bool> sendB = controller.send('@codex work in B');
    final String reqB = backend.sent.last['requestId']!;
    expect(controller.sending, isTrue);

    // Cancel in B cancels ONLY B's request, not A's.
    await controller.cancel();
    expect(backend.cancelled, <String>[reqB]);

    // Finish A while still viewing B: B must stay sending.
    roundA.complete();
    expect(await sendA, isTrue);
    expect(controller.sending, isTrue);

    // Finish B.
    roundB.complete();
    expect(await sendB, isTrue);
    expect(controller.sending, isFalse);

    // Switching back to A shows A is no longer sending.
    await controller.selectGroup(_builders);
    expect(controller.sending, isFalse);
  });

  test(
      'createGroup selects the newly created swarm by id even when names repeat',
      () async {
    await controller.start();
    const ChatGroup duplicate = ChatGroup(
      id: 'builders-new',
      name: 'Builders',
      members: <String>['claude'],
    );
    backend.createdGroup = duplicate;
    backend.createdList = <ChatGroup>[_builders, duplicate, _reviewers];

    final ChatGroup? result = await controller.createGroup(
      'Builders',
      const <String>['claude'],
    );
    expect(result?.id, 'builders-new');
    expect(controller.selected?.id, 'builders-new');
  });
}

const ChatGroup _builders = ChatGroup(
  id: 'builders',
  name: 'Builders',
  members: <String>['claude', 'codex'],
  workdir: '/trees/builders',
);
const ChatGroup _reviewers = ChatGroup(
  id: 'reviewers',
  name: 'Reviewers',
  members: <String>['codex'],
);
// Members on this machine, on Studio (10.0.0.5:8787) and on a machine this
// device has no credential for.
const ChatGroup _mixed = ChatGroup(
  id: 'mixed',
  name: 'Mixed',
  members: <String>['claude', '4e7eeaf61885:claude', '0123456789ab:codex'],
  peers: <String, SwarmPeer>{
    '4e7eeaf61885': SwarmPeer(name: 'Studio', baseUrl: 'http://10.0.0.5:8787'),
    '0123456789ab': SwarmPeer(name: 'Elsewhere', baseUrl: 'http://x.test'),
  },
);
const ChatGroup _other = ChatGroup(
  id: 'other',
  name: 'Other workspace',
  members: <String>['hermes'],
);

ChatMessage _message(
  String id,
  String content, {
  ChatRole role = ChatRole.user,
}) {
  return ChatMessage(
    id: id,
    role: role,
    content: content,
    createdAt: DateTime.utc(2026, 1, 2),
  );
}

class _GroupBackendClient extends BackendClient {
  String activeWorkdir = '/work/a';
  StreamController<BackendEvent> events =
      StreamController<BackendEvent>.broadcast(sync: true);
  final List<String> groupWorkdirs = <String>[];
  final List<String> historyRequests = <String>[];
  final Map<String, List<ChatMessage>> history = <String, List<ChatMessage>>{};
  final List<Map<String, String>> sent = <Map<String, String>>[];
  final List<List<MachineCredential>> sentPeers = <List<MachineCredential>>[];
  final List<String> cancelled = <String>[];
  final Completer<void> round = Completer<void>();
  final Map<String, Completer<void>> roundsByGroup =
      <String, Completer<void>>{};
  String? running;
  ChatGroup? createdGroup;
  List<ChatGroup>? createdList;

  void emit(String type, Map<String, Object?> data) {
    events.add(
      BackendEvent(
        type: type,
        data: <String, Object?>{'groupId': 'builders', ...data},
      ),
    );
  }

  @override
  Stream<BackendEvent> streamEvents() => events.stream;

  // Ends the current event stream, as a dropped connection does; the next
  // subscription gets a fresh one.
  void dropEvents() {
    final StreamController<BackendEvent> old = events;
    events = StreamController<BackendEvent>.broadcast(sync: true);
    old.close();
  }

  @override
  Future<List<ChatGroup>> fetchGroups() async {
    groupWorkdirs.add(activeWorkdir);
    return activeWorkdir == '/work/a'
        ? <ChatGroup>[_builders, _reviewers, _mixed]
        : <ChatGroup>[_other];
  }

  @override
  Future<GroupHistory> fetchGroupHistory(String groupId) async {
    historyRequests.add('$activeWorkdir:$groupId');
    return GroupHistory(
      group: <ChatGroup>[_builders, _reviewers, _mixed, _other]
          .firstWhere((ChatGroup g) => g.id == groupId),
      messages: history[groupId] ??
          <ChatMessage>[
            _message(groupId, 'History for $activeWorkdir:$groupId'),
          ],
      runningRequestId: running,
    );
  }

  @override
  Future<({ChatGroup group, List<ChatGroup> groups})> createGroup(
    String name,
    List<String> members, {
    String workdir = '',
    Map<String, Map<String, String>> configs =
        const <String, Map<String, String>>{},
    List<MachineCredential> peers = const <MachineCredential>[],
  }) async {
    final ChatGroup group = createdGroup ??
        ChatGroup(
          id: 'created',
          name: name,
          members: members,
          workdir: workdir,
        );
    final List<ChatGroup> list = createdList ?? <ChatGroup>[group];
    return (group: group, groups: list);
  }

  @override
  Future<void> sendGroupMessage({
    required String groupId,
    required String prompt,
    required String requestId,
    List<MachineCredential> peers = const <MachineCredential>[],
  }) {
    sentPeers.add(peers);
    sent.add(<String, String>{
      'groupId': groupId,
      'prompt': prompt,
      'requestId': requestId,
    });
    return (roundsByGroup[groupId] ?? round).future;
  }

  @override
  Future<void> cancelGroupMessage(String requestId) async {
    cancelled.add(requestId);
  }

  @override
  Future<void> close() async {
    await events.close();
    await super.close();
  }
}
