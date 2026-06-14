import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/chat_message.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/util/error_text.dart';

/// Drives the /btw sidekick popup: a small, read-only side chat that forks the
/// main conversation's memory on the backend. It is intentionally simpler than
/// [BotChatController] — one conversation, no sessions, no cross-device mirror,
/// no queue — because it never participates in the actual task.
class BtwController extends ChangeNotifier {
  BtwController({
    required BackendClient backendClient,
    required this.agentKey,
    required this.sessionId,
    required AppLanguage language,
  })  : _backend = backendClient,
        _language = language;

  static const String _streamingKey = 'streaming';
  static const String _awaitingKey = 'awaitingFirstToken';
  static const String _requestIdKey = 'requestId';
  static const String _errorKey = 'errorDetail';

  final BackendClient _backend;
  final String agentKey;
  final String sessionId;
  AppLanguage _language;

  final List<ChatMessage> _messages = <ChatMessage>[];
  String? _activeRequestId;
  bool _loading = false;
  bool _disposed = false;
  String? _lastError;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // Closing the popup mid-answer stops the side turn on the backend too.
    final String? requestId = _activeRequestId;
    if (requestId != null) {
      unawaited(_backend.cancelMessage(requestId).catchError((_) {}));
    }
    super.dispose();
  }

  List<ChatMessage> get messages => List<ChatMessage>.unmodifiable(_messages);
  bool get isThinking => _activeRequestId != null;
  bool get isLoading => _loading;
  String? get lastError => _lastError;
  AppStrings get _strings => AppStrings(_language);

  void setLanguage(AppLanguage language) => _language = language;

  Future<void> load() async {
    _loading = true;
    _notify();
    try {
      final List<ChatMessage> history =
          await _backend.fetchBtwHistory(agentKey, sessionId: sessionId);
      _messages
        ..clear()
        ..addAll(history);
    } catch (_) {
      // A side chat that fails to load just starts empty.
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<void> send(String rawText) async {
    final String text = rawText.trim();
    if (text.isEmpty || isThinking) return;
    _lastError = null;
    _messages.add(ChatMessage.user(text));

    final String requestId = 'btw.${DateTime.now().microsecondsSinceEpoch}';
    _activeRequestId = requestId;
    final ChatMessage placeholder = ChatMessage.assistant(
      '',
      metadata: <String, Object?>{
        _streamingKey: true,
        _awaitingKey: true,
        _requestIdKey: requestId,
      },
    );
    _messages.add(placeholder);
    _notify();

    final StringBuffer buffer = StringBuffer();
    try {
      final ChatReply reply = await _backend.sendBtwMessage(
        agentKey: agentKey,
        sessionId: sessionId,
        prompt: text,
        requestId: requestId,
        onEvent: (BackendEvent event) {
          switch (event.type) {
            case 'agent_delta':
              if (event.data['requestId'] != requestId) return;
              buffer.write(event.data['text'] as String? ?? '');
              _updatePlaceholder(requestId, buffer.toString(), streaming: true);
              break;
            case 'agent_segment':
              if (event.data['requestId'] != requestId) return;
              if (buffer.isNotEmpty) buffer.write('\n\n');
              break;
          }
        },
      );
      _updatePlaceholder(requestId, reply.content, streaming: false);
    } catch (err) {
      if (err is BackendException && err.code == 'AGENT_CANCELLED') {
        _updatePlaceholder(requestId, buffer.toString(), streaming: false);
      } else {
        final String detail = friendlyErrorText(_strings, err);
        _lastError = detail;
        _updatePlaceholder(
          requestId,
          buffer.toString(),
          streaming: false,
          error: detail,
        );
      }
    } finally {
      if (_activeRequestId == requestId) _activeRequestId = null;
      _notify();
    }
  }

  Future<void> cancel() async {
    final String? requestId = _activeRequestId;
    if (requestId == null) return;
    try {
      await _backend.cancelMessage(requestId);
    } catch (_) {
      // The turn may have already finished; the send path settles the state.
    }
  }

  Future<void> clear() async {
    if (isThinking) return;
    try {
      await _backend.clearBtw(agentKey, sessionId);
      _messages.clear();
      _lastError = null;
      _notify();
    } catch (err) {
      _lastError = friendlyErrorText(_strings, err);
      _notify();
    }
  }

  void _updatePlaceholder(
    String requestId,
    String content, {
    required bool streaming,
    String? error,
  }) {
    final int index = _messages.lastIndexWhere(
      (ChatMessage m) =>
          !m.isUser && m.metadata[_requestIdKey] == requestId,
    );
    if (index == -1) return;
    _messages[index] = _messages[index].copyWith(
      content: content,
      metadata: <String, Object?>{
        ..._messages[index].metadata,
        _streamingKey: streaming,
        _awaitingKey: streaming && content.isEmpty,
        if (error != null) _errorKey: error,
      },
    );
    _notify();
  }

  bool isStreaming(ChatMessage message) =>
      message.metadata[_streamingKey] == true;
  bool isAwaiting(ChatMessage message) =>
      message.metadata[_awaitingKey] == true;
  String? errorDetailFor(ChatMessage message) =>
      message.metadata[_errorKey] as String?;
}
