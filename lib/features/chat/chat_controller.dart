import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/llm/llm_client.dart';
import '../../core/models/agent.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/llm_provider.dart';
import '../../core/storage/api_keys_store.dart';
import '../../core/storage/chat_history_store.dart';

class ChatController extends ChangeNotifier {
  ChatController({
    ApiKeysStore? apiKeysStore,
    ChatHistoryStore? historyStore,
    LlmClient Function(Agent agent)? clientFactory,
    Duration charRevealInterval = const Duration(milliseconds: 18),
  })  : _apiKeysStore = apiKeysStore ?? ApiKeysStore(),
        _historyStore = historyStore ?? ChatHistoryStore(),
        _clientFactory = clientFactory ?? llmClientFor,
        _charRevealInterval = charRevealInterval;

  static const String _streamingKey = 'streaming';
  static const String _awaitingFirstTokenKey = 'awaitingFirstToken';
  static const String _deliveryFailedKey = 'deliveryFailed';
  static const String _errorDetailKey = 'errorDetail';

  final ApiKeysStore _apiKeysStore;
  final ChatHistoryStore _historyStore;
  final LlmClient Function(Agent agent) _clientFactory;
  final Duration _charRevealInterval;

  Agent? _agent;
  final List<ChatMessage> _messages = <ChatMessage>[];
  bool _isThinking = false;
  String? _lastError;

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);
  bool get isThinking => _isThinking;
  String? get lastError => _lastError;
  Agent? get agent => _agent;

  bool isRetryable(ChatMessage message) =>
      message.isUser && message.metadata[_deliveryFailedKey] == true;

  bool isAwaitingFirstToken(ChatMessage message) =>
      message.metadata[_awaitingFirstTokenKey] == true;

  String? errorDetailFor(ChatMessage message) =>
      message.metadata[_errorDetailKey] as String?;

  Future<void> loadFor(Agent? agent) async {
    if (_agent?.id == agent?.id) {
      _agent = agent;
      notifyListeners();
      return;
    }
    _agent = agent;
    _messages.clear();
    _lastError = null;
    _isThinking = false;
    notifyListeners();
    if (agent == null) return;
    final List<ChatMessage> loaded = await _historyStore.read(agent.id);
    if (_agent?.id != agent.id) return;
    _messages
      ..clear()
      ..addAll(loaded);
    notifyListeners();
  }

  Future<void> clearHistory() async {
    final Agent? agent = _agent;
    if (agent == null) return;
    _messages.clear();
    _lastError = null;
    await _historyStore.clear(agent.id);
    notifyListeners();
  }

  Future<void> sendUserText(String rawText) async {
    final String text = rawText.trim();
    final Agent? agent = _agent;
    if (text.isEmpty || _isThinking || agent == null) return;

    final ChatMessage userMessage = ChatMessage.user(text);
    _messages.add(userMessage);
    notifyListeners();
    await _persist();
    await _runTurn(agent, userMessage);
  }

  Future<void> retry(ChatMessage message) async {
    if (_isThinking || !isRetryable(message)) return;
    final Agent? agent = _agent;
    if (agent == null) return;
    final int index =
        _messages.indexWhere((ChatMessage m) => m.id == message.id);
    if (index == -1) return;
    _messages[index] = message.copyWith(metadata: const <String, Object?>{});
    notifyListeners();
    await _runTurn(agent, _messages[index]);
  }

  Future<void> _runTurn(Agent agent, ChatMessage userMessage) async {
    _isThinking = true;
    _lastError = null;
    notifyListeners();

    final int assistantIndex = _insertAwaitingAssistant();
    final List<String> revealQueue = <String>[];
    final StringBuffer displayed = StringBuffer();
    Timer? revealTimer;
    bool streamCompleted = false;
    final Completer<void> finalize = Completer<void>();

    void scheduleFinalize() {
      if (!finalize.isCompleted) finalize.complete();
    }

    void tick() {
      if (revealQueue.isEmpty) {
        if (streamCompleted) {
          revealTimer?.cancel();
          revealTimer = null;
          scheduleFinalize();
        }
        return;
      }
      final String ch = revealQueue.removeAt(0);
      displayed.write(ch);
      _updateStreamingAssistant(
        assistantIndex,
        content: displayed.toString(),
        awaitingFirstToken: false,
      );
    }

    void enqueue(String text) {
      if (text.isEmpty) return;
      for (final int rune in text.runes) {
        revealQueue.add(String.fromCharCode(rune));
      }
      if (_charRevealInterval == Duration.zero) {
        while (revealQueue.isNotEmpty) {
          tick();
        }
        return;
      }
      revealTimer ??= Timer.periodic(_charRevealInterval, (_) => tick());
    }

    void resetReveal() {
      revealTimer?.cancel();
      revealTimer = null;
      revealQueue.clear();
      displayed.clear();
    }

    try {
      final String? apiKey = await _apiKeysStore.read(agent.provider);
      if (apiKey == null) {
        throw LlmException(
          '未配置 ${agent.provider.label} 的 API key，请到设置里填写。',
        );
      }

      final LlmClient client = _clientFactory(agent);
      final List<ChatMessage> history = List<ChatMessage>.from(_messages)
        ..removeWhere(
          (ChatMessage m) => identical(m, _messages[assistantIndex]),
        );

      await for (final String chunk in client.stream(
        apiKey: apiKey,
        model: agent.model,
        systemPrompt: agent.systemPrompt,
        history: history,
        temperature: agent.temperature,
      )) {
        enqueue(chunk);
      }

      streamCompleted = true;
      if (revealQueue.isEmpty) {
        revealTimer?.cancel();
        revealTimer = null;
        scheduleFinalize();
      }
      await finalize.future;
      _finalizeAssistant(assistantIndex, displayed.toString());
      await _persist();
    } on LlmException catch (e) {
      resetReveal();
      _discardAssistant(assistantIndex);
      _markUserDeliveryFailed(userMessage.id, e.message);
      _lastError = e.message;
    } catch (e) {
      resetReveal();
      _discardAssistant(assistantIndex);
      _markUserDeliveryFailed(userMessage.id, e.toString());
      _lastError = e.toString();
    } finally {
      revealTimer?.cancel();
      _isThinking = false;
      notifyListeners();
    }
  }

  int _insertAwaitingAssistant() {
    _messages.add(
      ChatMessage.assistant(
        '',
        metadata: const <String, Object?>{
          _streamingKey: true,
          _awaitingFirstTokenKey: true,
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

  void _finalizeAssistant(int assistantIndex, String text) {
    if (assistantIndex >= _messages.length) {
      _messages.add(ChatMessage.assistant(text));
      notifyListeners();
      return;
    }
    _messages[assistantIndex] = _messages[assistantIndex].copyWith(
      content: text,
      metadata: const <String, Object?>{
        _streamingKey: false,
        _awaitingFirstTokenKey: false,
      },
    );
    notifyListeners();
  }

  void _discardAssistant(int assistantIndex) {
    if (assistantIndex >= _messages.length) return;
    _messages.removeAt(assistantIndex);
    notifyListeners();
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

  Future<void> _persist() async {
    final Agent? agent = _agent;
    if (agent == null) return;
    await _historyStore.write(agent.id, _messages);
  }
}
