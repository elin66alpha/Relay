import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/agent_session.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/machine_credential.dart';
import '../../core/notifications/fcm_service.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/notifications/web_push.dart';
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
  final Map<String, List<AgentSession>> _sessionsByAgent =
      <String, List<AgentSession>>{};
  final Map<String, String> _activeSessionByAgent = <String, String>{};
  final Set<String> _loadingSessions = <String>{};
  final List<ChatMessage> _messages = <ChatMessage>[];
  bool _isThinking = false;
  bool _isCancelling = false;
  String? _lastError;
  String? _activeRequestId;
  AppLanguage _language = AppLanguage.en;
  StreamSubscription<BackendEvent>? _eventsSub;
  Timer? _eventReconnectTimer;
  Timer? _historyPollTimer;
  Timer? _remoteSettleTimer;
  Timer? _streamNotifyTimer;
  bool _wantsEvents = false;
  bool _streamNotifyQueued = false;
  // True while another device is running a turn on the conversation we are
  // viewing (same workdir + agent + session). We mirror it by polling the backend's
  // authoritative history rather than replaying its deltas, which keeps the two
  // views identical without delta/snapshot races.
  bool _remoteActive = false;
  int _quotaScheduleRevision = 0;

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);
  int get messageCount => _messages.length;
  bool get isThinking => _isThinking;
  bool get isCancelling => _isCancelling;
  String? get lastError => _lastError;
  CliAgent get agent => _agent;
  MachineCredential? get machine => _machine;
  // Exposed so the composer's per-agent Model/Effort/Permission controls can
  // reach the same backend client (and thus the same workdir scope).
  BackendClient get backend => _backendClient;
  String? get activeSessionId => _activeSessionByAgent[_agent.key];
  AgentSession? get activeSession => sessionById(_agent.key, activeSessionId);
  int get quotaScheduleRevision => _quotaScheduleRevision;
  AppStrings get _strings => AppStrings(_language);

  String? activeSessionIdFor(String agentKey) =>
      _activeSessionByAgent[agentKey];

  AgentSession? activeSessionFor(String agentKey) {
    return sessionById(agentKey, activeSessionIdFor(agentKey));
  }

  List<AgentSession> sessionsFor(String agentKey) =>
      List<AgentSession>.unmodifiable(
        _sessionsByAgent[agentKey] ?? const <AgentSession>[],
      );

  bool sessionsLoadingFor(String agentKey) =>
      _loadingSessions.contains(agentKey);

  AgentSession? sessionById(String agentKey, String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return null;
    for (final AgentSession session
        in _sessionsByAgent[agentKey] ?? const <AgentSession>[]) {
      if (session.id == sessionId) return session;
    }
    return null;
  }

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

  Future<AgentSessionList?> _refreshSessionsFor(String agentKey) async {
    final MachineCredential? machine = _machine;
    if (machine == null) return null;
    _loadingSessions.add(agentKey);
    notifyListeners();
    try {
      final AgentSessionList result =
          await _backendClient.fetchSessions(agentKey);
      if (_machine?.id != machine.id) return null;
      _sessionsByAgent[agentKey] = result.sessions;
      _activeSessionByAgent[agentKey] = result.activeSession.id;
      return result;
    } finally {
      _loadingSessions.remove(agentKey);
      notifyListeners();
    }
  }

  void _clearSessionLists() {
    _sessionsByAgent.clear();
    _activeSessionByAgent.clear();
    _loadingSessions.clear();
  }

  void _prefetchInactiveSessions() {
    if (_machine == null) return;
    for (final CliAgent agent in defaultCliAgents) {
      if (agent.key == _agent.key || _sessionsByAgent.containsKey(agent.key)) {
        continue;
      }
      unawaited(_refreshSessionsFor(agent.key).catchError((_) => null));
    }
  }

  Future<String> _ensureActiveSessionId(CliAgent agent) async {
    final String? current = _activeSessionByAgent[agent.key];
    if (current != null && current.isNotEmpty) return current;
    final AgentSessionList? result = await _refreshSessionsFor(agent.key);
    final AgentSession? active = result?.activeSession;
    if (active != null) return active.id;
    return AgentSession.defaultId;
  }

  Future<void> createSessionFor(CliAgent agent, {String name = ''}) async {
    final MachineCredential? machine = _machine;
    if (_isThinking || machine == null) return;
    final AgentSessionList result =
        await _backendClient.createSession(agent.key, name);
    if (_machine?.id != machine.id) return;
    _sessionsByAgent[agent.key] = result.sessions;
    _activeSessionByAgent[agent.key] = result.activeSession.id;
    _agent = agent;
    await _reloadConversation();
  }

  Future<void> selectSession(CliAgent agent, String sessionId) async {
    final MachineCredential? machine = _machine;
    if (_isThinking || machine == null || sessionId.isEmpty) return;
    final AgentSessionList result =
        await _backendClient.selectSession(agent.key, sessionId);
    if (_machine?.id != machine.id) return;
    _sessionsByAgent[agent.key] = result.sessions;
    _activeSessionByAgent[agent.key] = result.activeSession.id;
    _agent = agent;
    await _reloadConversation();
  }

  Future<void> deleteSession(CliAgent agent, String sessionId) async {
    final MachineCredential? machine = _machine;
    if (_isThinking || machine == null || sessionId.isEmpty) return;
    final AgentSessionList result =
        await _backendClient.deleteSession(agent.key, sessionId);
    if (_machine?.id != machine.id) return;
    _sessionsByAgent[agent.key] = result.sessions;
    _activeSessionByAgent[agent.key] = result.activeSession.id;
    if (_agent.key == agent.key) {
      await _reloadConversation();
    } else {
      notifyListeners();
    }
  }

  void setLanguage(AppLanguage language) {
    _language = language;
  }

  bool isRetryable(ChatMessage message) =>
      message.isUser && message.metadata[_deliveryFailedKey] == true;

  bool isAwaitingFirstToken(ChatMessage message) =>
      message.metadata[_awaitingFirstTokenKey] == true;

  bool isStreaming(ChatMessage message) =>
      message.metadata[_streamingKey] == true;

  bool isSystemMessage(ChatMessage message) =>
      message.metadata[_systemKey] == true;

  bool isCancelled(ChatMessage message) =>
      message.metadata[_cancelledKey] == true;

  String? errorDetailFor(ChatMessage message) =>
      message.metadata[_errorDetailKey] as String?;

  List<String> progressLinesFor(ChatMessage message) {
    if (message.metadata[_streamingKey] != true) return const <String>[];
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
    final bool machineChanged = _machine?.id != machine.id;
    _agent = agent;
    _machine = machine;
    if (machineChanged) _clearSessionLists();
    if (sameContext && activeSessionId != null) {
      notifyListeners();
      return;
    }
    _messages.clear();
    _lastError = null;
    _isThinking = false;
    _isCancelling = false;
    _activeRequestId = null;
    _remoteActive = false;
    _remoteSettleTimer?.cancel();
    _stopHistoryPolling();
    notifyListeners();

    // Check login state for the new context so the banner can warn up front.
    unawaited(refreshAuthStatus());
    _prefetchInactiveSessions();

    // Pull the previous conversation so reopening the app shows it. Best-effort:
    // ignore failures (offline / no history), and never clobber messages the
    // user has already typed or sent while this was in flight.
    try {
      final String sessionId = await _ensureActiveSessionId(agent);
      final List<ChatMessage> history =
          await _backendClient.fetchHistory(agent.key, sessionId: sessionId);
      if (_agent.key != agent.key ||
          _machine?.id != machine.id ||
          activeSessionId != sessionId ||
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
    final String sessionId = await _ensureActiveSessionId(agent);
    // Reset the machine-side session first; otherwise the next prompt may
    // resume context that the user just cleared locally. Only wipe the on-screen
    // history once the backend confirms — if the clear fails (e.g. a turn is
    // running → SESSION_BUSY), keep the messages so the view doesn't lie.
    try {
      await _backendClient.clearSession(agent.key, sessionId);
      await _refreshSessionsFor(agent.key);
    } catch (err) {
      _appendSystemMessage(_strings.localChatSessionResetFailed(err));
      return;
    }
    _stopHistoryPolling();
    _messages.clear();
    _lastError = null;
    notifyListeners();
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
      final String sessionId = await _ensureActiveSessionId(_agent);
      await _backendClient.compressConversation(
        agentKey: _agent.key,
        sessionId: sessionId,
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

  Future<String> statusText(
    AppStrings strings, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final BackendDiagnostics diagnostics =
          await _backendClient.diagnostics(timeout: timeout);
      return diagnostics.toDisplayText(strings);
    } on BackendException catch (err) {
      if (err.status != 404) rethrow;
      final BackendStatus status =
          await _backendClient.status(timeout: timeout);
      return status.toDisplayText(strings);
    }
  }

  Future<UsageReport> usageReport() => _backendClient.usageReport();

  // Registers this browser for Web Push so quota/scheduled-message alerts arrive
  // even when the tab is closed. Web-only and best-effort: a no-op off the web,
  // when the backend has no VAPID keys, or until the user grants permission
  // (retried on the next app open). Runs at most once per session.
  bool _pushSynced = false;
  Future<void> syncPushSubscription() async {
    if (_pushSynced || _machine == null || !webPushSupported()) return;
    try {
      final PushConfig config = await _backendClient.pushConfig();
      if (!config.enabled || config.publicKey.isEmpty) {
        _pushSynced = true;
        return;
      }
      final String? subscription = await webPushSubscribe(config.publicKey);
      if (subscription == null) return; // permission not granted yet
      await _backendClient.subscribePush(
        subscription,
        _strings.isZh ? 'zh' : 'en',
      );
      _pushSynced = true;
    } catch (_) {
      // Best-effort; the next app open retries.
    }
  }

  // Registers this mobile device for FCM so quota/scheduled-message alerts can
  // arrive while the app is backgrounded or killed. Android/iOS only and
  // best-effort; web/desktop and missing Firebase config are no-ops.
  bool _fcmSynced = false;
  Future<void> syncFcmRegistration() async {
    if (_fcmSynced || _machine == null) return;
    try {
      final bool handled = await FcmService.instance.syncRegistration(
        backendClient: _backendClient,
        lang: _strings.isZh ? 'zh' : 'en',
      );
      if (handled) _fcmSynced = true;
    } catch (_) {
      // Best-effort; the next app open retries.
    }
  }

  Future<List<DeviceToken>> deviceTokens() => _backendClient.deviceTokens();

  Future<void> revokeDeviceToken(String id) =>
      _backendClient.revokeDeviceToken(id);

  Future<List<ChatHistorySearchResult>> searchHistory(
    String query, {
    bool currentAgentOnly = false,
  }) {
    return _backendClient.searchHistory(
      query,
      agentKey: currentAgentOnly ? _agent.key : null,
    );
  }

  Future<ConversationExport> exportCurrentSessionMarkdown() async {
    final String sessionId = await _ensureActiveSessionId(_agent);
    return _backendClient.exportHistory(_agent.key, sessionId: sessionId);
  }

  Future<List<QuotaSchedule>> quotaSchedules() =>
      _backendClient.quotaSchedules();

  Future<QuotaSchedule> createQuotaSchedule({
    required String sourceKey,
    required String agentKey,
    required String prompt,
    String? targetResetsAt,
    bool replaceExisting = false,
  }) async {
    final CliAgent agent = cliAgentByKey(agentKey);
    final String sessionId = await _ensureActiveSessionId(agent);
    return _backendClient.createQuotaSchedule(
      sourceKey: sourceKey,
      agentKey: agent.key,
      sessionId: sessionId,
      prompt: prompt,
      targetResetsAt: targetResetsAt,
      replaceExisting: replaceExisting,
    );
  }

  Future<void> cancelQuotaSchedule(String id) =>
      _backendClient.cancelQuotaSchedule(id);

  Future<WorkdirInfo> workdir() => _backendClient.workdir();

  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) async {
    final WorkdirInfo info =
        await _backendClient.setWorkdir(path, create: create);
    // Switching paths switches conversations: the session is keyed by
    // workdir + agent + chat session. Reconnect the event stream with the new
    // workdir and reload the shared history for this path so it shows immediately.
    _clearSessionLists();
    await reconnectEvents();
    await _reloadConversation();
    return info;
  }

  /// Clears the view and pulls the shared conversation for the current
  /// workdir + agent + session. Used after switching the work directory.
  Future<void> _reloadConversation() async {
    final MachineCredential? machine = _machine;
    if (machine == null) return;
    final CliAgent agent = _agent;
    _messages.clear();
    _lastError = null;
    _isThinking = false;
    _isCancelling = false;
    _activeRequestId = null;
    _remoteActive = false;
    _remoteSettleTimer?.cancel();
    _stopHistoryPolling();
    notifyListeners();
    unawaited(refreshAuthStatus());
    try {
      final String sessionId = await _ensureActiveSessionId(agent);
      final List<ChatMessage> history =
          await _backendClient.fetchHistory(agent.key, sessionId: sessionId);
      if (_agent.key != agent.key ||
          _machine?.id != machine.id ||
          activeSessionId != sessionId) {
        return;
      }
      _messages
        ..clear()
        ..addAll(history);
      _restorePendingTurnFromHistory();
      if (_isThinking) _startHistoryPolling();
      notifyListeners();
    } catch (_) {
      // Leave the view empty when history can't be loaded.
    }
    _prefetchInactiveSessions();
  }

  Future<FsListing> browseWorkdir(
    String path, {
    bool showHidden = false,
  }) =>
      _backendClient.browseWorkdir(path, showHidden: showHidden);

  Future<FsDownloadStream> openFileDownload(String path) =>
      _backendClient.openFileDownload(path);

  Future<FsEntry> uploadFile({
    required String path,
    required String name,
    required Uint8List bytes,
  }) =>
      _backendClient.uploadFile(path: path, name: name, bytes: bytes);

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
    _remoteSettleTimer?.cancel();
    _cancelStreamingNotifyTimer();
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
    if (!(_isThinking || _remoteActive) || machine == null) {
      _stopHistoryPolling();
      return;
    }
    final CliAgent agent = _agent;
    final String? sessionId = activeSessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    try {
      final List<ChatMessage> history =
          await _backendClient.fetchHistory(agent.key, sessionId: sessionId);
      if (_agent.key != agent.key ||
          _machine?.id != machine.id ||
          activeSessionId != sessionId) {
        return;
      }
      if (history.isEmpty) return;
      // Never clobber our own in-flight turn (our chat stream is the smoother,
      // authoritative source for it); only mirror when the activity is remote.
      if (_isThinking && !_remoteActive) return;
      _messages
        ..clear()
        ..addAll(history);
      _restorePendingTurnFromHistory();
      if (!(_isThinking || _remoteActive)) _stopHistoryPolling();
      notifyListeners();
    } catch (_) {
      // Keep the last visible snapshot; the next poll/event may recover.
    }
  }

  // A turn started by another device on the conversation we are viewing. Mirror
  // it from persisted history. Skip while we have our own turn in flight; we do
  // a catch-up refresh when ours finishes.
  void _beginRemoteMirror() {
    if (_isThinking) return;
    _remoteSettleTimer?.cancel();
    _remoteActive = true;
    _startHistoryPolling();
    unawaited(_refreshHistorySnapshot());
  }

  // A remote turn finished. Do a final refresh shortly after so the snapshot
  // captures the finalized (non-streaming) message, then stop mirroring.
  void _endRemoteMirror() {
    if (!_remoteActive) return;
    unawaited(_refreshHistorySnapshot());
    _remoteSettleTimer?.cancel();
    _remoteSettleTimer = Timer(const Duration(milliseconds: 900), () {
      _remoteActive = false;
      unawaited(_refreshHistorySnapshot());
      if (!_isThinking) _stopHistoryPolling();
    });
  }

  Future<void> _runTurn(CliAgent agent, ChatMessage userMessage) async {
    _isThinking = true;
    _isCancelling = false;
    _lastError = null;
    notifyListeners();

    final String requestId = _newRequestId(agent);
    _activeRequestId = requestId;

    try {
      final String sessionId = await _ensureActiveSessionId(agent);
      _insertAwaitingAssistant(requestId: requestId);
      final ChatReply reply = await _backendClient.sendMessage(
        agentKey: agent.key,
        sessionId: sessionId,
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
      // A remote turn may have started and finished on this scope while ours was
      // in flight (we skip mirroring then). Catch up to the shared truth now.
      unawaited(_catchUpHistory());
    }
  }

  // One-shot pull of the shared history, used after our own turn ends to pick up
  // any changes other devices made meanwhile. No-op if a new turn is running.
  Future<void> _catchUpHistory() async {
    final MachineCredential? machine = _machine;
    if (_isThinking || _remoteActive || machine == null) return;
    final CliAgent agent = _agent;
    final String? sessionId = activeSessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    try {
      final List<ChatMessage> history =
          await _backendClient.fetchHistory(agent.key, sessionId: sessionId);
      if (_agent.key != agent.key ||
          _machine?.id != machine.id ||
          activeSessionId != sessionId ||
          _isThinking ||
          _remoteActive ||
          history.isEmpty) {
        return;
      }
      _messages
        ..clear()
        ..addAll(history);
      _restorePendingTurnFromHistory();
      if (_isThinking) _startHistoryPolling();
      notifyListeners();
    } catch (_) {
      // Best-effort; the next interaction will reconcile.
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
    _notifyStreamingUpdate();
  }

  void _finalizeAssistant(
    int assistantIndex,
    String text, {
    bool system = false,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    _cancelStreamingNotifyTimer();
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
    _cancelStreamingNotifyTimer();
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
    _cancelStreamingNotifyTimer();
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

  void _notifyStreamingUpdate() {
    if (_streamNotifyTimer != null) {
      _streamNotifyQueued = true;
      return;
    }
    notifyListeners();
    _streamNotifyTimer = Timer(const Duration(milliseconds: 80), () {
      _streamNotifyTimer = null;
      if (!_streamNotifyQueued) return;
      _streamNotifyQueued = false;
      _notifyStreamingUpdate();
    });
  }

  void _cancelStreamingNotifyTimer() {
    _streamNotifyTimer?.cancel();
    _streamNotifyTimer = null;
    _streamNotifyQueued = false;
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
      _handleScopeEvent,
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

  // Events for our own in-flight turn, delivered on the chat POST stream.
  void _handleEvent(BackendEvent event) {
    switch (event.type) {
      case 'agent_delta':
        _appendDelta(event.data);
        return;
      case 'agent_progress':
        _appendProgress(event.data);
        return;
      case 'agent_queued':
        final String requestId = event.data['requestId'] as String? ?? '';
        if (requestId.isNotEmpty) {
          _appendProgress(<String, Object?>{
            'requestId': requestId,
            'line': _strings.agentQueued,
          });
        }
        return;
      case 'agent_cancelled':
        final String requestId = event.data['requestId'] as String? ?? '';
        if (requestId.isNotEmpty) {
          _markAssistantCancelled(requestId);
        }
        return;
      case 'agent_error':
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
  }

  // Events on the shared event stream, scoped by the backend to our current
  // work directory. Drives quota alerts and cross-device mirroring: a turn
  // started on another device in the same path is mirrored here from history.
  void _handleScopeEvent(BackendEvent event) {
    if (event.type == 'quota_reset') {
      final String message = _strings.isZh
          ? event.data['messageZh'] as String? ??
              event.data['message'] as String? ??
              ''
          : event.data['message'] as String? ?? '';
      if (message.isEmpty) return;
      // Quota alerts prefer a system/browser notification. If the platform
      // denies it, fall back to an in-page system message for Web users.
      unawaited(_showQuotaNotification(message));
      return;
    }
    if (event.type == 'quota_schedule_sent' ||
        event.type == 'quota_schedule_failed') {
      _quotaScheduleRevision += 1;
      notifyListeners();
      final String message = _strings.isZh
          ? event.data['messageZh'] as String? ??
              event.data['message'] as String? ??
              ''
          : event.data['message'] as String? ?? '';
      if (message.isEmpty) return;
      unawaited(_showQuotaNotification(message));
      return;
    }
    if (event.type == 'quota_schedule_changed') {
      _quotaScheduleRevision += 1;
      notifyListeners();
      return;
    }

    final String requestId = event.data['requestId'] as String? ?? '';
    if (requestId.isEmpty) return;
    // Our own turn is driven by the chat POST stream; ignore its echo here.
    if (requestId == _activeRequestId) return;
    // Only mirror activity for the agent we are currently viewing.
    final Map<String, Object?> agentData =
        (event.data['agent'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final String agentKey = agentData['key'] as String? ?? '';
    if (agentKey.isNotEmpty && agentKey != _agent.key) return;
    final Map<String, Object?> sessionData =
        (event.data['session'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final String sessionId = sessionData['id'] as String? ?? '';
    // Only drop an event when we actually know which session we're viewing.
    // While sessions are still loading (activeSessionId == null) we let events
    // through; the history poll then reconciles against the correct session.
    final String? active = activeSessionId;
    if (sessionId.isNotEmpty &&
        active != null &&
        active.isNotEmpty &&
        sessionId != active) {
      return;
    }

    switch (event.type) {
      case 'agent_start':
      case 'agent_queued':
      case 'agent_delta':
      case 'agent_progress':
        _beginRemoteMirror();
        return;
      case 'agent_done':
      case 'agent_cancelled':
      case 'agent_error':
        _endRemoteMirror();
        return;
    }
  }

  Future<void> _showQuotaNotification(String message) async {
    try {
      final bool shown = await NotificationService.instance.show(
        title: 'Relay',
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
