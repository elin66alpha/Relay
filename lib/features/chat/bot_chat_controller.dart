import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/backend/backend_client.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/machine_credential.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/storage/chat_history_store.dart';

class BotChatController extends ChangeNotifier {
  BotChatController({
    BackendClient? backendClient,
    ChatHistoryStore? historyStore,
  })  : _backendClient = backendClient ?? BackendClient(),
        _historyStore = historyStore ?? ChatHistoryStore();

  static const String _streamingKey = 'streaming';
  static const String _awaitingFirstTokenKey = 'awaitingFirstToken';
  static const String _deliveryFailedKey = 'deliveryFailed';
  static const String _errorDetailKey = 'errorDetail';
  static const String _systemKey = 'system';
  static const String _requestIdKey = 'requestId';
  static const String _progressLinesKey = 'progressLines';
  static const String _cancelledKey = 'cancelled';

  final BackendClient _backendClient;
  final ChatHistoryStore _historyStore;

  CliAgent _agent = defaultCliAgents.first;
  MachineCredential? _machine;
  final List<ChatMessage> _messages = <ChatMessage>[];
  bool _isThinking = false;
  bool _isCancelling = false;
  String? _lastError;
  String? _activeRequestId;
  StreamSubscription<BackendEvent>? _eventsSub;
  Timer? _eventReconnectTimer;
  bool _wantsEvents = false;

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);
  bool get isThinking => _isThinking;
  bool get isCancelling => _isCancelling;
  String? get lastError => _lastError;
  CliAgent get agent => _agent;
  MachineCredential? get machine => _machine;

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
    if (_agent.key == agent.key &&
        _machine?.id == machine.id &&
        _messages.isNotEmpty) {
      _agent = agent;
      _machine = machine;
      notifyListeners();
      return;
    }
    _agent = agent;
    _machine = machine;
    _messages.clear();
    _lastError = null;
    _isThinking = false;
    _isCancelling = false;
    _activeRequestId = null;
    notifyListeners();

    final List<ChatMessage> loaded =
        await _historyStore.read(_historyKey(agent, machine));
    if (_agent.key != agent.key || _machine?.id != machine.id) return;
    _messages
      ..clear()
      ..addAll(loaded);
    notifyListeners();
  }

  Future<void> clearHistory() async {
    final CliAgent agent = _agent;
    _messages.clear();
    _lastError = null;
    final MachineCredential? machine = _machine;
    if (machine != null) {
      await _historyStore.clear(_historyKey(agent, machine));
    }
    notifyListeners();
    // 同时重置后端会话，否则下一条消息会 resume 已删除的上下文。
    // 尽力而为：后端不可达时仍保留本地清空结果，只提示一句。
    try {
      await _backendClient.clearSession(agent.key);
    } catch (err) {
      _appendSystemMessage('已清空本地对话，但重置机器会话失败：$err');
    }
  }

  Future<void> sendUserText(String rawText) async {
    final String text = rawText.trim();
    if (text.isEmpty || _isThinking || _machine == null) return;

    final ChatMessage userMessage = ChatMessage.user(text);
    _messages.add(userMessage);
    notifyListeners();
    await _persist();
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
        // 请求已结束（成功或已取消）。不强行标记取消——交给 _runTurn 的正常
        // 收尾按真实结果处理（成功则 finalize，已取消则走 AGENT_CANCELLED）。
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

  Future<String> statusText() async {
    final BackendStatus status = await _backendClient.status();
    return status.toDisplayText();
  }

  Future<UsageReport> usageReport() => _backendClient.usageReport();

  Future<WorkdirInfo> workdir() => _backendClient.workdir();

  Future<WorkdirInfo> checkWorkdir(String path) =>
      _backendClient.checkWorkdir(path);

  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) =>
      _backendClient.setWorkdir(path, create: create);

  Future<void> appendUsage() async {
    if (_isThinking) return;
    _isThinking = true;
    _lastError = null;
    notifyListeners();
    final int assistantIndex = _insertAwaitingAssistant(system: true);
    try {
      final String usage = await _backendClient.usage(_agent.key);
      _finalizeAssistant(assistantIndex, usage, system: true);
      await _persist();
    } catch (err) {
      _discardAssistant(assistantIndex);
      _lastError = err.toString();
      _appendSystemMessage('额度查询失败：$err');
    } finally {
      _isThinking = false;
      notifyListeners();
    }
  }

  Future<void> resetWorkdir() async {
    if (_isThinking) return;
    _isThinking = true;
    _lastError = null;
    notifyListeners();
    try {
      final WorkdirResetResult result = await _backendClient.resetWorkdir();
      _appendSystemMessage('已清空工作目录（删除 ${result.count} 项）：${result.dir}');
      await _persist();
    } catch (err) {
      _lastError = err.toString();
      _appendSystemMessage('清空工作目录失败：$err');
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
    await _eventsSub?.cancel();
    await _backendClient.close();
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
      await _persist();
    } catch (err) {
      if (err is BackendException && err.code == 'AGENT_CANCELLED') {
        _markAssistantCancelled(requestId);
        await _persist();
      } else {
        _discardAssistantByRequestId(requestId);
        final String detail =
            err is BackendException && err.code == 'AGENT_BUSY'
                ? '该 agent 正在处理上一条消息，请稍后重试。'
                : err.toString();
        _markUserDeliveryFailed(userMessage.id, detail);
        _lastError = detail;
        await _persist();
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
    // 只在消息仍处于 streaming 时追加。POST 最终结果到达后会 _finalizeAssistant
    // 把 streaming 置 false；此后迟到的 SSE delta 必须丢弃，否则会把碎片追加到
    // 权威答案末尾、并把气泡永久翻回 streaming 状态。
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

  Future<void> _persist() async {
    final MachineCredential? machine = _machine;
    if (machine == null) return;
    await _historyStore.write(_historyKey(_agent, machine), _messages);
  }

  String _historyKey(CliAgent agent, MachineCredential machine) =>
      'machine.${machine.id}.cli.${agent.key}';

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
        _persist();
      }
      return;
    }
    if (event.type == 'agent_error') {
      final String requestId = event.data['requestId'] as String? ?? '';
      final String error = event.data['error'] as String? ?? '';
      if (requestId.isNotEmpty && error.isNotEmpty) {
        _appendProgress(<String, Object?>{
          'requestId': requestId,
          'line': '出错：$error',
        });
      }
      return;
    }
    if (event.type != 'quota_reset') return;
    final String message = event.data['message'] as String? ?? '';
    if (message.isEmpty) return;
    // Quota alerts go to the OS notification tray, not the chat bubble stream.
    // Fire-and-forget: a denied/unsupported notification must not break events.
    unawaited(
      NotificationService.instance.show(title: 'AgentDeck', body: message),
    );
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
