import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/machine_credential.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/settings/app_settings_controller.dart';

class BotChatController extends ChangeNotifier {
  BotChatController({
    BackendClient? backendClient,
  }) : _backendClient = backendClient ?? BackendClient();

  static const String _streamingKey = 'streaming';
  static const String _awaitingFirstTokenKey = 'awaitingFirstToken';
  static const String _deliveryFailedKey = 'deliveryFailed';
  static const String _errorDetailKey = 'errorDetail';
  static const String _systemKey = 'system';
  static const String _requestIdKey = 'requestId';
  static const String _progressLinesKey = 'progressLines';
  static const String _cancelledKey = 'cancelled';

  final BackendClient _backendClient;

  CliAgent _agent = defaultCliAgents.first;
  MachineCredential? _machine;
  final Map<String, bool?> _authStatus = <String, bool?>{};
  final List<ChatMessage> _messages = <ChatMessage>[];
  bool _isThinking = false;
  bool _isCancelling = false;
  String? _lastError;
  String? _activeRequestId;
  AppLanguage _language = AppLanguage.en;
  StreamSubscription<BackendEvent>? _eventsSub;
  Timer? _eventReconnectTimer;
  Timer? _historyPollTimer;
  bool _wantsEvents = false;

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);
  bool get isThinking => _isThinking;
  bool get isCancelling => _isCancelling;
  String? get lastError => _lastError;
  CliAgent get agent => _agent;
  MachineCredential? get machine => _machine;
  AppStrings get _strings => AppStrings(_language);

  /// Login state for an agent CLI on the backend host: true/false when known,
  /// or null when unchecked or undeterminable (e.g. agy). Drives the
  /// "not logged in" banner; it never blocks sending, since detection is
  /// best-effort and a real failure is still caught when the turn runs.
  bool? agentLoggedIn(String agentKey) => _authStatus[agentKey];

  /// Refreshes per-agent login state from the backend. Best-effort: a probe
  /// failure (offline, older backend without the endpoint) is ignored.
  Future<void> refreshAuthStatus() async {
    if (_machine == null) return;
    try {
      final Map<String, bool?> status = await _backendClient.fetchAuthStatus();
      _authStatus
        ..clear()
        ..addAll(status);
      notifyListeners();
    } catch (_) {
      // A probe failure must not interfere with chatting.
    }
  }

  void setLanguage(AppLanguage language) {
    _language = language;
  }

  bool isRetryable(ChatMessage message) =>
      message.isUser && message.metadata[_deliveryFailedKey] == true;

  bool isAwaitingFirstToken(ChatMessage message) =>
      message.metadata[_awaitingFirstTokenKey] == true;

  bool isSystemMessage(ChatMessage message) =>
      message.metadata[_systemKey] == true;

  bool isCancelled(ChatMessage message) =>
      message.metadata[_cancelledKey] == true;

  String? errorDetailFor(ChatMessage message) =>
      message.metadata[_errorDetailKey] as String?;

  List<String> progressLinesFor(ChatMessage message) {
    final Object? raw = message.metadata[_progressLinesKey];
    if (raw is! List) return const <String>[];
    return raw.whereType<String>().toList(growable: false);
  }

  Future<void> loadFor(CliAgent agent, MachineCredential machine) async {
    // The app keeps no local chat history: the backend (CLI host) owns it and
    // we fetch it back here. Keep the in-memory messages while the agent/machine
    // is unchanged; switching either starts fresh and reloads from the backend.
    final bool sameContext =
        _agent.key == agent.key && _machine?.id == machine.id;
    _agent = agent;
    _machine = machine;
    if (sameContext) {
      notifyListeners();
      return;
    }
    _messages.clear();
    _lastError = null;
    _isThinking = false;
    _isCancelling = false;
    _activeRequestId = null;
    _stopHistoryPolling();
    notifyListeners();

    // Check login state for the new context so the banner can warn up front.
    unawaited(refreshAuthStatus());

    // Pull the previous conversation so reopening the app shows it. Best-effort:
    // ignore failures (offline / no history), and never clobber messages the
    // user has already typed or sent while this was in flight.
    try {
      final List<ChatMessage> history =
          await _backendClient.fetchHistory(agent.key);
      if (_agent.key != agent.key ||
          _machine?.id != machine.id ||
          _messages.isNotEmpty) {
        return;
      }
      _messages.addAll(history);
      _restorePendingTurnFromHistory();
      if (_isThinking) _startHistoryPolling();
      notifyListeners();
    } catch (_) {
      // Leave the view empty when history can't be loaded.
    }
  }

  Future<void> clearHistory() async {
    final CliAgent agent = _agent;
    _stopHistoryPolling();
    _messages.clear();
    _lastError = null;
    notifyListeners();
    // Also reset the machine-side session; otherwise the next prompt may
    // resume context that the user just cleared locally.
    try {
      await _backendClient.clearSession(agent.key);
    } catch (err) {
      _appendSystemMessage(_strings.localChatSessionResetFailed(err));
    }
  }

  Future<void> compressConversation() async {
    if (_isThinking || _machine == null) return;
    _isThinking = true;
    _isCancelling = false;
    _lastError = null;
    final String requestId = _newRequestId(_agent);
    _activeRequestId = requestId;
    notifyListeners();
    try {
      await _backendClient.compressConversation(
        agentKey: _agent.key,
        requestId: requestId,
      );
    } catch (err) {
      _lastError = err.toString();
      rethrow;
    } finally {
      if (_activeRequestId == requestId) _activeRequestId = null;
      _isThinking = false;
      _isCancelling = false;
      notifyListeners();
    }
  }

  Future<void> sendUserText(String rawText) async {
    final String text = rawText.trim();
    if (text.isEmpty || _isThinking || _machine == null) return;

    final ChatMessage userMessage = ChatMessage.user(text);
    _messages.add(userMessage);
    notifyListeners();
    await _runTurn(_agent, userMessage);
  }

  Future<void> cancelActiveTurn() async {
    final String? requestId = _activeRequestId;
    if (!_isThinking || _isCancelling || requestId == null) return;
    _isCancelling = true;
    notifyListeners();
    try {
      await _backendClient.cancelMessage(requestId);
    } catch (err) {
      if (err is BackendException && err.code == 'REQUEST_NOT_FOUND') {
        // The request already finished. Let _runTurn finish with the real
        // outcome instead of forcing a cancelled state here.
        return;
      }
      _lastError = err.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> retry(ChatMessage message) async {
    if (_isThinking || _machine == null || !isRetryable(message)) return;
    final int index =
        _messages.indexWhere((ChatMessage m) => m.id == message.id);
    if (index == -1) return;
    _messages[index] = message.copyWith(metadata: const <String, Object?>{});
    notifyListeners();
    await _runTurn(_agent, _messages[index]);
  }

  Future<String> statusText(AppStrings strings) async {
    final BackendStatus status = await _backendClient.status();
    return status.toDisplayText(strings);
  }

  Future<UsageReport> usageReport() => _backendClient.usageReport();

  Future<WorkdirInfo> workdir() => _backendClient.workdir();

  Future<WorkdirInfo> checkWorkdir(String path) =>
      _backendClient.checkWorkdir(path);

  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) =>
      _backendClient.setWorkdir(path, create: create);

  Future<FsListing> listFiles(
    String path, {
    bool showHidden = false,
  }) =>
      _backendClient.listFiles(path, showHidden: showHidden);

  Future<FsListing> browseWorkdir(
    String path, {
    bool showHidden = false,
  }) =>
      _backendClient.browseWorkdir(path, showHidden: showHidden);

  Future<FsDownload> downloadFile(String path) =>
      _backendClient.downloadFile(path);

  Future<FsEntry> uploadFile({
    required String path,
    required String name,
    required Uint8List bytes,
  }) =>
      _backendClient.uploadFile(path: path, name: name, bytes: bytes);

  Future<void> resetWorkdir() async {
    if (_isThinking) return;
    _isThinking = true;
    _lastError = null;
    notifyListeners();
    try {
      final WorkdirResetResult result = await _backendClient.resetWorkdir();
      _appendSystemMessage(
        _strings.workdirResetSuccess(result.count, result.dir),
      );
    } catch (err) {
      _lastError = err.toString();
      _appendSystemMessage(_strings.workdirResetFailed(err));
    } finally {
      _isThinking = false;
      notifyListeners();
    }
  }

  void connectEvents() {
    _wantsEvents = true;
    _connectEventsNow();
  }

  Future<void> reconnectEvents() async {
    _eventReconnectTimer?.cancel();
    await _eventsSub?.cancel();
    _eventsSub = null;
    if (_wantsEvents) _connectEventsNow();
  }

  Future<void> disposeController() async {
    _wantsEvents = false;
    _eventReconnectTimer?.cancel();
    _historyPollTimer?.cancel();
    await _eventsSub?.cancel();
    await _backendClient.close();
  }

  void _restorePendingTurnFromHistory() {
    ChatMessage? pending;
    for (int i = _messages.length - 1; i >= 0; i -= 1) {
      final ChatMessage message = _messages[i];
      if (!message.isUser && message.metadata[_streamingKey] == true) {
        pending = message;
        break;
      }
    }

    final String requestId = pending?.metadata[_requestIdKey] as String? ?? '';
    if (pending != null && requestId.isNotEmpty) {
      _isThinking = true;
      _isCancelling = false;
      _activeRequestId = requestId;
      return;
    }
    _isThinking = false;
    _isCancelling = false;
    _activeRequestId = null;
  }

  void _startHistoryPolling() {
    if (_historyPollTimer != null) return;
    _historyPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshHistorySnapshot()),
    );
  }

  void _stopHistoryPolling() {
    _historyPollTimer?.cancel();
    _historyPollTimer = null;
  }

  Future<void> _refreshHistorySnapshot() async {
    final MachineCredential? machine = _machine;
    if (!_isThinking || machine == null) {
      _stopHistoryPolling();
      return;
    }
    final CliAgent agent = _agent;
    try {
      final List<ChatMessage> history =
          await _backendClient.fetchHistory(agent.key);
      if (_agent.key != agent.key || _machine?.id != machine.id) return;
      if (history.isEmpty) return;
      _messages
        ..clear()
        ..addAll(history);
      _restorePendingTurnFromHistory();
      if (!_isThinking) _stopHistoryPolling();
      notifyListeners();
    } catch (_) {
      // Keep the last visible snapshot; the next poll/event may recover.
    }
  }

  Future<void> _runTurn(CliAgent agent, ChatMessage userMessage) async {
    _isThinking = true;
    _isCancelling = false;
    _lastError = null;
    notifyListeners();

    final String requestId = _newRequestId(agent);
    _activeRequestId = requestId;
    _insertAwaitingAssistant(requestId: requestId);

    try {
      final ChatReply reply = await _backendClient.sendMessage(
        agentKey: agent.key,
        prompt: userMessage.content,
        requestId: requestId,
        onEvent: _handleEvent,
      );
      _finalizeAssistantByRequestId(
        requestId,
        reply.content,
        metadata: <String, Object?>{
          _requestIdKey: reply.requestId,
          'agentKey': reply.agentKey,
          'agentLabel': reply.agentLabel,
        },
      );
    } catch (err) {
      if (err is BackendException && err.code == 'AGENT_CANCELLED') {
        _markAssistantCancelled(requestId);
      } else {
        _discardAssistantByRequestId(requestId);
        String detail = err.toString();
        if (err is BackendException && err.code == 'AGENT_BUSY') {
          detail = _strings.agentBusyRetryLater;
        } else if (err is BackendException && err.code == 'NOT_LOGGED_IN') {
          detail = _strings.agentNotLoggedIn(agent.label);
          // Reflect the failure in the banner right away.
          _authStatus[agent.key] = false;
        }
        _markUserDeliveryFailed(userMessage.id, detail);
        _lastError = detail;
      }
    } finally {
      if (_activeRequestId == requestId) _activeRequestId = null;
      _isThinking = false;
      _isCancelling = false;
      notifyListeners();
    }
  }

  int _insertAwaitingAssistant({bool system = false, String? requestId}) {
    _messages.add(
      ChatMessage.assistant(
        '',
        metadata: <String, Object?>{
          _streamingKey: true,
          _awaitingFirstTokenKey: true,
          if (requestId != null) _requestIdKey: requestId,
          if (system) _systemKey: true,
        },
      ),
    );
    notifyListeners();
    return _messages.length - 1;
  }

  void _updateStreamingAssistant(
    int assistantIndex, {
    required String content,
    required bool awaitingFirstToken,
  }) {
    if (assistantIndex >= _messages.length) return;
    _messages[assistantIndex] = _messages[assistantIndex].copyWith(
      content: content,
      metadata: <String, Object?>{
        ..._messages[assistantIndex].metadata,
        _streamingKey: true,
        _awaitingFirstTokenKey: awaitingFirstToken,
      },
    );
    notifyListeners();
  }

  void _finalizeAssistant(
    int assistantIndex,
    String text, {
    bool system = false,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final Map<String, Object?> finalMetadata = <String, Object?>{
      _streamingKey: false,
      _awaitingFirstTokenKey: false,
      if (system) _systemKey: true,
      ...metadata,
    };
    if (assistantIndex >= _messages.length) {
      _messages.add(ChatMessage.assistant(text, metadata: finalMetadata));
      notifyListeners();
      return;
    }
    _messages[assistantIndex] = _messages[assistantIndex].copyWith(
      content: text,
      metadata: finalMetadata,
    );
    notifyListeners();
  }

  void _finalizeAssistantByRequestId(
    String requestId,
    String text, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;
    _finalizeAssistant(
      index,
      text,
      metadata: <String, Object?>{
        _requestIdKey: requestId,
        ...metadata,
      },
    );
  }

  void _discardAssistant(int assistantIndex) {
    if (assistantIndex >= _messages.length) return;
    _messages.removeAt(assistantIndex);
    notifyListeners();
  }

  void _discardAssistantByRequestId(String requestId) {
    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;
    _discardAssistant(index);
  }

  void _appendDelta(Map<String, Object?> data) {
    final String requestId = data['requestId'] as String? ?? '';
    final String text = data['text'] as String? ?? '';
    if (requestId.isEmpty || text.isEmpty) return;

    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;
    final ChatMessage current = _messages[index];
    // Append only while the bubble is still streaming. Once the POST response
    // finalizes the authoritative answer, late SSE deltas must be ignored.
    if (isCancelled(current) || current.metadata[_streamingKey] != true) return;

    _updateStreamingAssistant(
      index,
      content: '${current.content}$text',
      awaitingFirstToken: false,
    );
  }

  void _markAssistantCancelled(String requestId) {
    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;
    final ChatMessage message = _messages[index];
    _messages[index] = message.copyWith(
      content: message.content,
      metadata: <String, Object?>{
        ...message.metadata,
        _streamingKey: false,
        _awaitingFirstTokenKey: false,
        _cancelledKey: true,
      },
    );
    notifyListeners();
  }

  int _assistantIndexForRequest(String requestId) {
    if (requestId.isEmpty) return -1;
    return _messages.indexWhere(
      (ChatMessage message) =>
          !message.isUser && message.metadata[_requestIdKey] == requestId,
    );
  }

  void _markUserDeliveryFailed(String localId, String detail) {
    final int index = _messages.indexWhere((ChatMessage m) => m.id == localId);
    if (index == -1) return;
    _messages[index] = _messages[index].copyWith(
      metadata: <String, Object?>{
        ..._messages[index].metadata,
        _deliveryFailedKey: true,
        _errorDetailKey: detail,
      },
    );
    notifyListeners();
  }

  void _appendSystemMessage(String text) {
    _messages.add(
      ChatMessage.assistant(
        text,
        metadata: const <String, Object?>{_systemKey: true},
      ),
    );
    notifyListeners();
  }

  String _newRequestId(CliAgent agent) {
    final int micros = DateTime.now().microsecondsSinceEpoch;
    return '${agent.key}.$micros';
  }

  void _connectEventsNow() {
    if (!_wantsEvents || _eventsSub != null) return;
    _eventsSub = _backendClient.streamEvents().listen(
      _handleEvent,
      onError: (Object error) {
        _eventsSub = null;
        _scheduleEventReconnect();
      },
      onDone: () {
        _eventsSub = null;
        _scheduleEventReconnect();
      },
      cancelOnError: true,
    );
  }

  void _scheduleEventReconnect() {
    if (!_wantsEvents || _eventReconnectTimer != null) return;
    _eventReconnectTimer = Timer(const Duration(seconds: 15), () {
      _eventReconnectTimer = null;
      _connectEventsNow();
    });
  }

  void _handleEvent(BackendEvent event) {
    if (event.type == 'agent_delta') {
      _appendDelta(event.data);
      return;
    }
    if (event.type == 'agent_progress') {
      _appendProgress(event.data);
      return;
    }
    if (event.type == 'agent_cancelled') {
      final String requestId = event.data['requestId'] as String? ?? '';
      if (requestId.isNotEmpty) {
        _markAssistantCancelled(requestId);
      }
      return;
    }
    if (event.type == 'agent_error') {
      final String requestId = event.data['requestId'] as String? ?? '';
      final String error = event.data['error'] as String? ?? '';
      if (requestId.isNotEmpty && error.isNotEmpty) {
        _appendProgress(<String, Object?>{
          'requestId': requestId,
          'line': _strings.agentErrorLine(error),
        });
      }
      return;
    }
    if (event.type != 'quota_reset') return;
    final String message = _strings.isZh
        ? event.data['messageZh'] as String? ??
            event.data['message'] as String? ??
            ''
        : event.data['message'] as String? ?? '';
    if (message.isEmpty) return;
    // Quota alerts prefer a system/browser notification. If the platform denies
    // it, fall back to an in-page system message so Web users still see it.
    unawaited(_showQuotaNotification(message));
  }

  Future<void> _showQuotaNotification(String message) async {
    try {
      final bool shown = await NotificationService.instance.show(
        title: 'AgentDeck',
        body: message,
      );
      if (!shown) _appendSystemMessage(message);
    } catch (_) {
      _appendSystemMessage(message);
    }
  }

  void _appendProgress(Map<String, Object?> data) {
    final String requestId = data['requestId'] as String? ?? '';
    final String line = data['line'] as String? ?? '';
    if (requestId.isEmpty || line.isEmpty) return;

    final int index = _assistantIndexForRequest(requestId);
    if (index == -1) return;

    final List<String> lines =
        progressLinesFor(_messages[index]).toList(growable: true);
    if (lines.isEmpty || lines.last != line) lines.add(line);
    while (lines.length > 6) {
      lines.removeAt(0);
    }

    _messages[index] = _messages[index].copyWith(
      metadata: <String, Object?>{
        ..._messages[index].metadata,
        _progressLinesKey: lines,
      },
    );
    notifyListeners();
  }
}
