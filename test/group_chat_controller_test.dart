import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/models/chat_message.dart';
import 'package:relay/core/models/group.dart';
import 'package:relay/features/chat/group_chat_controller.dart';

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

  test(
      'sends one human message, streams member replies, and reconciles history',
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

    backend
        .emit('agent_delta', <String, Object?>{...member, 'text': 'Checking'});
    backend.emit('agent_delta', <String, Object?>{...member, 'text': ' files'});
    expect(controller.messages.last.content, 'Checking files');
    expect(controller.messages.last.metadata['awaitingFirstToken'], isFalse);
    backend.emit('agent_segment', member);
    backend.emit(
      'agent_delta',
      <String, Object?>{...member, 'text': 'Looks good'},
    );
    expect(controller.messages.last.content, 'Checking files\n\nLooks good');
    expect(
      controller.messages.last.segments.map((MessageSegment s) => s.text),
      <String>['Checking files', 'Looks good'],
    );
    backend.emit('agent_done', member);
    expect(controller.messages.last.metadata['streaming'], isFalse);

    final ChatMessage reply = _message(
      memberRequestId,
      'Saved reply',
      role: ChatRole.assistant,
    );
    backend.history['builders'] = <ChatMessage>[human, reply];
    backend.round.complete();
    expect(await sending, isTrue);
    expect(controller.sending, isFalse);
    expect(controller.messages, <ChatMessage>[human, reply]);
    expect(backend.historyRequests, <String>[
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
    backend.emit('agent_delta', <String, Object?>{
      'requestId': memberRequestId,
      'text': 'Partial reply',
      'agent': <String, Object?>{'key': 'claude', 'label': 'Claude Code'},
    });
    await controller.cancel();
    expect(backend.cancelled, <String>[requestId]);

    backend.emit('agent_cancelled', <String, Object?>{
      'requestId': memberRequestId,
    });
    expect(controller.messages.last.content, 'Partial reply');
    expect(controller.messages.last.metadata['streaming'], isFalse);
    expect(controller.messages.last.metadata['cancelled'], isTrue);
    backend.history['builders'] = controller.messages;
    backend.round.completeError(
      BackendException('request cancelled', code: 'AGENT_CANCELLED'),
    );

    expect(await sending, isTrue);
    expect(controller.sending, isFalse);
    expect(controller.error, isNull);
    expect(controller.messages.last.content, 'Partial reply');
    expect(backend.historyRequests, hasLength(2));
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
  final StreamController<BackendEvent> events =
      StreamController<BackendEvent>.broadcast(sync: true);
  final List<String> groupWorkdirs = <String>[];
  final List<String> historyRequests = <String>[];
  final Map<String, List<ChatMessage>> history = <String, List<ChatMessage>>{};
  final List<Map<String, String>> sent = <Map<String, String>>[];
  final List<String> cancelled = <String>[];
  final Completer<void> round = Completer<void>();

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

  @override
  Future<List<ChatGroup>> fetchGroups() async {
    groupWorkdirs.add(activeWorkdir);
    return activeWorkdir == '/work/a'
        ? <ChatGroup>[_builders, _reviewers]
        : <ChatGroup>[_other];
  }

  @override
  Future<GroupHistory> fetchGroupHistory(String groupId) async {
    historyRequests.add('$activeWorkdir:$groupId');
    return GroupHistory(
      group: <ChatGroup>[_builders, _reviewers, _other]
          .firstWhere((ChatGroup g) => g.id == groupId),
      messages: history[groupId] ??
          <ChatMessage>[
            _message(groupId, 'History for $activeWorkdir:$groupId'),
          ],
    );
  }

  @override
  Future<void> sendGroupMessage({
    required String groupId,
    required String prompt,
    required String requestId,
  }) {
    sent.add(<String, String>{
      'groupId': groupId,
      'prompt': prompt,
      'requestId': requestId,
    });
    return round.future;
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
