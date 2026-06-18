import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/group.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/util/error_text.dart';

/// Drives the multi-agent group chat screen. The send path is plain JSON; all
/// live updates (the human echo and each summoned agent's streaming reply) arrive
/// on the shared `/api/events` stream tagged with `groupId`, so one subscription
/// renders both this device's and other devices' activity. After a round ends the
/// transcript is reloaded from the backend to reconcile the authoritative
/// segments against the live bubbles built from deltas.
class GroupChatController extends ChangeNotifier {
  GroupChatController({BackendClient? backendClient})
      : _client = backendClient ?? BackendClient();

  static const String _streamingKey = 'streaming';
  static const String _awaitingFirstTokenKey = 'awaitingFirstToken';
  static const String _segmentsKey = 'segments';
  static const String _cancelledKey = 'cancelled';
  static const String _authorKey = 'author';
  static const String _agentLabelKey = 'agentLabel';

  final BackendClient _client;
  // Per-request live segments mirroring the single-agent chat: a member's
  // mid-task follow-up notes and its final answer are kept as separate,
  // individually timestamped messages instead of one growing block, so the
  // bubble can show per-segment times and collapse the earlier ones.
  final Map<String, List<_StreamSegment>> _streamSegments =
      <String, List<_StreamSegment>>{};
  final Random _random = Random();
  AppLanguage _language = AppLanguage.en;
  AppStrings get _strings => AppStrings(_language);

  set language(AppLanguage language) {
    if (_language == language) return;
    _language = language;
  }

  List<ChatGroup> _groups = <ChatGroup>[];
  ChatGroup? _selected;
  final List<ChatMessage> _messages = <ChatMessage>[];
  bool _loadingGroups = false;
  bool _loadingHistory = false;
  String? _activeRequestId;
  String? _error;
  StreamSubscription<BackendEvent>? _eventsSub;
  Timer? _reconnectTimer;
  bool _disposed = false;

  /// The shared backend client, exposed so the swarm form can browse work trees
  /// and fetch per-agent option catalogs without opening a second connection.
  BackendClient get backend => _client;

  List<ChatGroup> get groups => List<ChatGroup>.unmodifiable(_groups);
  ChatGroup? get selected => _selected;
  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);
  bool get loadingGroups => _loadingGroups;
  bool get loadingHistory => _loadingHistory;
  bool get sending => _activeRequestId != null;
  String? get error => _error;

  String? _initialGroupId;

  Future<void> start({String? initialGroupId}) async {
    _initialGroupId = initialGroupId;
    _subscribeEvents();
    await loadGroups();
  }

  Future<void> loadGroups() async {
    _loadingGroups = true;
    _error = null;
    _safeNotify();
    try {
      _groups = await _client.fetchGroups();
      // Honor a requested swarm (drawer sub-entry) on first load, then forget it.
      if (_initialGroupId != null) {
        _selected = _groups.cast<ChatGroup?>().firstWhere(
              (ChatGroup? g) => g?.id == _initialGroupId,
              orElse: () => _selected,
            );
        _initialGroupId = null;
      }
      // Keep the selection if it still exists; otherwise pick the first group.
      if (_selected != null) {
        _selected = _groups.cast<ChatGroup?>().firstWhere(
              (ChatGroup? g) => g?.id == _selected!.id,
              orElse: () => null,
            );
      }
      _selected ??= _groups.isNotEmpty ? _groups.first : null;
    } on BackendException catch (err) {
      _error = friendlyErrorText(_strings, err);
    } finally {
      _loadingGroups = false;
      _safeNotify();
    }
    if (_selected != null) await _loadHistory(_selected!.id);
  }

  Future<void> selectGroup(ChatGroup group) async {
    if (_selected?.id == group.id) return;
    _selected = group;
    _messages.clear();
    _streamSegments.clear();
    _safeNotify();
    await _loadHistory(group.id);
  }

  Future<ChatGroup?> createGroup(
    String name,
    List<String> members, {
    String workdir = '',
    Map<String, Map<String, String>> configs =
        const <String, Map<String, String>>{},
  }) async {
    _error = null;
    try {
      _groups = await _client.createGroup(
        name,
        members,
        workdir: workdir,
        configs: configs,
      );
      final ChatGroup created = _groups.firstWhere(
        (ChatGroup g) => g.name == name,
        orElse: () => _groups.first,
      );
      _selected = created;
      _messages.clear();
      _safeNotify();
      return created;
    } on BackendException catch (err) {
      _error = friendlyErrorText(_strings, err);
      _safeNotify();
      return null;
    }
  }

  Future<bool> updateMembers(
    ChatGroup group,
    List<String> members, {
    Map<String, Map<String, String>> configs =
        const <String, Map<String, String>>{},
  }) async {
    _error = null;
    try {
      _groups = await _client.setGroupMembers(
        group.id,
        members,
        configs: configs,
      );
      _selected = _groups.firstWhere(
        (ChatGroup g) => g.id == group.id,
        orElse: () => _selected ?? group,
      );
      _safeNotify();
      return true;
    } on BackendException catch (err) {
      _error = friendlyErrorText(_strings, err);
      _safeNotify();
      return false;
    }
  }

  Future<void> deleteGroup(ChatGroup group) async {
    _error = null;
    try {
      _groups = await _client.deleteGroup(group.id);
      if (_selected?.id == group.id) {
        _selected = _groups.isNotEmpty ? _groups.first : null;
        _messages.clear();
      }
      _safeNotify();
      if (_selected != null) await _loadHistory(_selected!.id);
    } on BackendException catch (err) {
      _error = friendlyErrorText(_strings, err);
      _safeNotify();
    }
  }

  Future<void> clearTranscript() async {
    final ChatGroup? group = _selected;
    if (group == null) return;
    _error = null;
    try {
      await _client.clearGroup(group.id);
      _messages.clear();
      _safeNotify();
    } on BackendException catch (err) {
      _error = friendlyErrorText(_strings, err);
      _safeNotify();
    }
  }

  Future<bool> send(String rawText) async {
    final ChatGroup? group = _selected;
    final String text = rawText.trim();
    if (group == null || text.isEmpty || sending) return false;
    final String requestId = _newRequestId();
    bool sent = false;
    _activeRequestId = requestId;
    _error = null;
    // Optimistic human bubble with the id the backend will use, so the echoed
    // group_message event upserts in place instead of duplicating.
    _upsert(
      ChatMessage(
        id: '$requestId:human',
        role: ChatRole.user,
        content: text,
        createdAt: DateTime.now(),
        metadata: const <String, Object?>{_authorKey: 'human'},
      ),
    );
    _safeNotify();
    try {
      await _client.sendGroupMessage(
        groupId: group.id,
        prompt: text,
        requestId: requestId,
      );
      sent = true;
    } on BackendException catch (err) {
      if (err.code != 'AGENT_CANCELLED') {
        _error = friendlyErrorText(_strings, err);
      } else {
        sent = true;
      }
    } finally {
      _activeRequestId = null;
      _safeNotify();
      await _loadHistory(group.id);
    }
    return sent;
  }

  Future<void> cancel() async {
    final String? requestId = _activeRequestId;
    if (requestId == null) return;
    try {
      await _client.cancelGroupMessage(requestId);
    } on BackendException {
      // The round may have just finished; the reload below reconciles state.
    }
  }

  Future<void> _loadHistory(String groupId) async {
    _loadingHistory = true;
    _safeNotify();
    try {
      final GroupHistory history = await _client.fetchGroupHistory(groupId);
      if (_selected?.id != groupId) return;
      // Authoritative history (which already carries per-segment timestamps)
      // supersedes any live segments still buffered for this round.
      _streamSegments.clear();
      _messages
        ..clear()
        ..addAll(history.messages);
    } on BackendException catch (err) {
      _error = friendlyErrorText(_strings, err);
    } finally {
      _loadingHistory = false;
      _safeNotify();
    }
  }

  // --- Shared event stream ---------------------------------------------------

  void _subscribeEvents() {
    _eventsSub?.cancel();
    _eventsSub = _client.streamEvents().listen(
          _handleEvent,
          onError: (Object _) => _scheduleReconnect(),
          onDone: _scheduleReconnect,
          cancelOnError: true,
        );
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), _subscribeEvents);
  }

  void _handleEvent(BackendEvent event) {
    final Map<String, Object?> data = event.data;
    final String? groupId = data['groupId'] as String?;
    final ChatGroup? group = _selected;
    if (group == null || groupId == null || groupId != group.id) return;

    switch (event.type) {
      case 'group_message':
        final Map<String, Object?> message =
            (data['message'] as Map?)?.cast<String, Object?>() ??
                const <String, Object?>{};
        final String id = message['id'] as String? ?? '';
        if (id.isEmpty) return;
        _upsert(
          ChatMessage(
            id: id,
            role: ChatRole.user,
            content: message['content'] as String? ?? '',
            createdAt: _parseTime(message['createdAt']),
            metadata: <String, Object?>{_authorKey: 'human'},
          ),
        );
        _safeNotify();
        break;
      case 'agent_start':
        _ensureBubble(data);
        _safeNotify();
        break;
      case 'agent_delta':
        final String requestId = data['requestId'] as String? ?? '';
        final String text = data['text'] as String? ?? '';
        if (requestId.isEmpty || text.isEmpty) return;
        _appendDelta(data, requestId, text);
        _safeNotify();
        break;
      case 'agent_segment':
        final String requestId = data['requestId'] as String? ?? '';
        if (requestId.isEmpty) return;
        _openSegmentBoundary(data, requestId);
        _safeNotify();
        break;
      case 'agent_cancelled':
        _stopStreaming(data['requestId'] as String? ?? '', cancelled: true);
        _safeNotify();
        break;
      case 'agent_done':
      case 'agent_error':
        _stopStreaming(data['requestId'] as String? ?? '');
        _safeNotify();
        break;
      case 'group_done':
      case 'group_cancelled':
        // A round driven by another device finished; reconcile our transcript.
        if (data['requestId'] != _activeRequestId) {
          _loadHistory(group.id);
        }
        break;
      default:
        break;
    }
  }

  // Find or create the streaming assistant bubble for a per-agent turn, keyed by
  // its requestId. Author + label come from the event's agent payload.
  ChatMessage _ensureBubble(Map<String, Object?> data) {
    final String requestId = data['requestId'] as String? ?? '';
    final int index = _indexOf(requestId);
    if (index != -1) return _messages[index];
    final Map<String, Object?> agent =
        (data['agent'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final ChatMessage bubble = ChatMessage(
      id: requestId,
      role: ChatRole.assistant,
      content: '',
      createdAt: DateTime.now(),
      metadata: <String, Object?>{
        _streamingKey: true,
        _awaitingFirstTokenKey: true,
        _authorKey: agent['key'] as String? ?? '',
        _agentLabelKey: agent['label'] as String? ?? '',
      },
    );
    _messages.add(bubble);
    return bubble;
  }

  // Append streamed text to the request's bubble, opening the first segment on
  // the first delta and clearing the awaiting-first-token state.
  void _appendDelta(Map<String, Object?> data, String requestId, String text) {
    final ChatMessage bubble = _ensureBubble(data);
    final List<_StreamSegment> segments = _streamSegments.putIfAbsent(
      requestId,
      () => <_StreamSegment>[_StreamSegment(DateTime.now())],
    );
    if (segments.isEmpty) segments.add(_StreamSegment(DateTime.now()));
    segments.last.buffer.write(text);
    _writeBubble(bubble, requestId);
  }

  // The member started a new follow-up message in the same turn: open a fresh
  // segment so it shows as its own timestamped block under the collapse toggle.
  void _openSegmentBoundary(Map<String, Object?> data, String requestId) {
    final ChatMessage bubble = _ensureBubble(data);
    _streamSegments
        .putIfAbsent(requestId, () => <_StreamSegment>[])
        .add(_StreamSegment(DateTime.now()));
    _writeBubble(bubble, requestId);
  }

  // Reflect the live segments into the bubble's flat content + segments metadata,
  // so a single-segment turn renders as one block and a multi-segment one shows
  // each follow-up with its own time behind the collapse toggle.
  void _writeBubble(ChatMessage bubble, String requestId) {
    final List<_StreamSegment> segments =
        _streamSegments[requestId] ?? const <_StreamSegment>[];
    final String content =
        segments.map((_StreamSegment s) => s.buffer.toString()).join('\n\n');
    _upsert(
      bubble.copyWith(
        content: content,
        metadata: <String, Object?>{
          ...bubble.metadata,
          _streamingKey: true,
          _awaitingFirstTokenKey: false,
          _segmentsKey: _serializeSegments(requestId),
        },
      ),
    );
  }

  List<Map<String, Object?>> _serializeSegments(String requestId) {
    final List<_StreamSegment> segments =
        _streamSegments[requestId] ?? const <_StreamSegment>[];
    return segments
        .map(
          (_StreamSegment s) => <String, Object?>{
            'ts': s.createdAt.toIso8601String(),
            'text': s.buffer.toString(),
          },
        )
        .toList(growable: false);
  }

  // End a member's live stream. Final segments are reconciled from authoritative
  // history when the round reloads; this just settles the live bubble's state.
  void _stopStreaming(String requestId, {bool cancelled = false}) {
    if (requestId.isEmpty) return;
    _streamSegments.remove(requestId);
    final int index = _indexOf(requestId);
    if (index == -1) return;
    final ChatMessage bubble = _messages[index];
    _messages[index] = bubble.copyWith(
      metadata: <String, Object?>{
        ...bubble.metadata,
        _streamingKey: false,
        _awaitingFirstTokenKey: false,
        if (cancelled) _cancelledKey: true,
      },
    );
  }

  int _indexOf(String id) =>
      _messages.indexWhere((ChatMessage m) => m.id == id);

  void _upsert(ChatMessage message) {
    final int index = _indexOf(message.id);
    if (index == -1) {
      _messages.add(message);
    } else {
      _messages[index] = message;
    }
  }

  DateTime _parseTime(Object? raw) =>
      DateTime.tryParse(raw as String? ?? '') ?? DateTime.now();

  String _newRequestId() {
    final int a = _random.nextInt(0x100000000);
    final int b = DateTime.now().microsecondsSinceEpoch;
    return 'g-$b-$a';
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _eventsSub?.cancel();
    _client.close();
    super.dispose();
  }
}

/// A live, in-progress assistant segment held while a member's reply streams.
/// Serialized into the message's `metadata['segments']` so the bubble can show
/// each follow-up message with its own arrival time.
class _StreamSegment {
  _StreamSegment(this.createdAt);

  final DateTime createdAt;
  final StringBuffer buffer = StringBuffer();
}
