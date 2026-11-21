import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/group.dart';
import '../../core/models/machine_credential.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/util/error_text.dart';

/// Drives the multi-agent group chat screen. The send path is plain JSON; the
/// human echo and each member's start and finish arrive on the shared
/// `/api/events` stream tagged with `groupId`, so one subscription shows both
/// this device's and other devices' activity. Replies are not streamed: a
/// member shows as working until it finishes, then the transcript is reloaded
/// to show its whole reply.
///
/// [machines] lists this device's machine credentials. Requests that reach a
/// swarm's remote members carry the credentials of those members' machines;
/// a member whose machine is not among them cannot run from this device.
class GroupChatController extends ChangeNotifier {
  GroupChatController({
    BackendClient? backendClient,
    List<MachineCredential> Function()? machines,
  })  : _client = backendClient ?? BackendClient(),
        _machines = machines ?? (() => const <MachineCredential>[]);

  static const String _streamingKey = 'streaming';
  static const String _awaitingFirstTokenKey = 'awaitingFirstToken';
  static const String _authorKey = 'author';
  static const String _agentLabelKey = 'agentLabel';

  final BackendClient _client;
  final List<MachineCredential> Function() _machines;
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
  // Running rounds keyed by group id: either started by this device or
  // reported running by the backend on load, so Stop is per swarm and survives
  // switching swarms or leaving and returning.
  final Map<String, String> _activeRequestIds = <String, String>{};
  // Group ids whose send() call from this device is currently in flight.
  final Set<String> _postingGroups = <String>{};
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
  bool get sending =>
      _selected != null && _activeRequestIds.containsKey(_selected!.id);
  String? get error => _error;

  List<MachineCredential> _peersFor(Iterable<String> members) =>
      peerCredentialsFor(members, _machines());

  /// Whether this device can run [member]: always for a member on this
  /// machine, and for a remote one only with its machine's credential.
  bool isMemberLinked(String member) =>
      memberPeerId(member) == null || _peersFor(<String>[member]).isNotEmpty;

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
      final (:ChatGroup group, :List<ChatGroup> groups) =
          await _client.createGroup(
        name,
        members,
        workdir: workdir,
        configs: configs,
        peers: _peersFor(members),
      );
      _groups = groups;
      final ChatGroup created = _groups.firstWhere(
        (ChatGroup g) => g.id == group.id,
        orElse: () => group,
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
        peers: _peersFor(<String>{...group.members, ...members}),
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

  Future<bool> updateWorkdir(
    ChatGroup group, {
    String workdir = '',
    Map<String, String> memberWorkdirs = const <String, String>{},
  }) async {
    _error = null;
    try {
      _groups = await _client.setGroupWorkdir(
        group.id,
        workdir: workdir,
        memberWorkdirs: memberWorkdirs,
        peers: _peersFor(group.members),
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
      _groups = await _client.deleteGroup(
        group.id,
        peers: _peersFor(group.members),
      );
      _activeRequestIds.remove(group.id);
      _postingGroups.remove(group.id);
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
      await _client.clearGroup(group.id, peers: _peersFor(group.members));
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
    if (group == null ||
        text.isEmpty ||
        _activeRequestIds.containsKey(group.id)) {
      return false;
    }
    final String groupId = group.id;
    final String requestId = _newRequestId();
    bool sent = false;
    BackendException? dropped;
    _activeRequestIds[groupId] = requestId;
    _postingGroups.add(groupId);
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
        groupId: groupId,
        prompt: text,
        requestId: requestId,
        peers: _peersFor(group.members),
      );
      sent = true;
    } on BackendException catch (err) {
      if (err.code == 'AGENT_CANCELLED') {
        sent = true;
      } else if (err.code?.startsWith('NETWORK_') ?? false) {
        // The request dropped or timed out (a long round, a phone in the
        // background) while the round may still run; history decides below.
        dropped = err;
      } else {
        _error = friendlyErrorText(_strings, err);
      }
    } finally {
      if (_activeRequestIds[groupId] == requestId) {
        _activeRequestIds.remove(groupId);
      }
      _postingGroups.remove(groupId);
      _safeNotify();
      final GroupHistory? history = await _loadHistory(groupId);
      if (dropped != null) {
        // Recorded means the round started: the reload restored its Stop and
        // its events finish it, so only an unrecorded message failed.
        sent = history?.messages
                .any((ChatMessage m) => m.id == '$requestId:human') ??
            false;
        if (!sent) {
          _error = friendlyErrorText(_strings, dropped);
          _safeNotify();
        }
      }
    }
    return sent;
  }

  Future<void> cancel() async {
    final String? groupId = _selected?.id;
    final String? requestId =
        groupId == null ? null : _activeRequestIds[groupId];
    if (requestId == null) return;
    try {
      await _client.cancelGroupMessage(requestId);
    } on BackendException {
      // The round may have just finished; the reload below reconciles state.
    }
  }

  // The swarm's history as loaded, or null when it could not be read.
  Future<GroupHistory?> _loadHistory(String groupId) async {
    _safeNotify();
    try {
      final GroupHistory history = await _client.fetchGroupHistory(groupId);
      if (!_postingGroups.contains(groupId)) {
        final String? running = history.runningRequestId;
        if (running != null && running.isNotEmpty) {
          _activeRequestIds[groupId] = running;
        } else {
          _activeRequestIds.remove(groupId);
        }
      }
      if (_selected?.id != groupId) return history;
      _messages
        ..clear()
        ..addAll(history.messages);
      return history;
    } on BackendException catch (err) {
      if (_selected?.id == groupId) {
        _error = friendlyErrorText(_strings, err);
      }
      return null;
    } finally {
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
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      _subscribeEvents();
      // Events sent while the stream was down (such as a round's group_done)
      // are gone, so re-read the open swarm rather than trust its last state.
      final String? groupId = _selected?.id;
      if (groupId != null) _loadHistory(groupId);
    });
  }

  void _handleEvent(BackendEvent event) {
    final Map<String, Object?> data = event.data;
    final String? groupId = data['groupId'] as String?;
    if (groupId == null) return;
    final ChatGroup? group = _selected;
    final bool isSelected = group != null && groupId == group.id;

    switch (event.type) {
      case 'group_done':
      case 'group_cancelled':
        final String? eventRequestId = data['requestId'] as String?;
        final bool ownPosting = _postingGroups.contains(groupId) &&
            eventRequestId == _activeRequestIds[groupId];
        if (!ownPosting &&
            (eventRequestId == null ||
                _activeRequestIds[groupId] == eventRequestId)) {
          _activeRequestIds.remove(groupId);
        }
        if (isSelected && !ownPosting) {
          _loadHistory(groupId);
        } else if (!ownPosting) {
          _safeNotify();
        }
        break;
      case 'group_message':
        if (!isSelected) return;
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
      case 'group_agent_start':
      case 'agent_start':
        if (!isSelected) return;
        _ensureBubble(data);
        _safeNotify();
        break;
      case 'group_agent_done':
      case 'group_agent_error':
      case 'group_agent_cancelled':
      case 'agent_done':
      case 'agent_error':
      case 'agent_cancelled':
        if (!isSelected) return;
        // The member's whole reply is in the transcript now.
        _loadHistory(groupId);
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
