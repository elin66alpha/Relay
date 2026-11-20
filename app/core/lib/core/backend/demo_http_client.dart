import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/machine_credential.dart';
import '../settings/app_settings_controller.dart';

/// In-memory HTTP client for Demo mode (`https://demo.relay.invalid`).
///
/// Answers supported Relay API routes with canned payloads and streams a fixed
/// reply over SSE for `/api/chat` without touching the network.
class DemoHttpClient extends http.BaseClient {
  DemoHttpClient({
    this.language,
    this.chunkDelay = const Duration(milliseconds: 15),
    this.chunkSize = 5,
  });

  static const String demoReplyEn =
      'This is Relay demo mode; the agent does not actually run. '
      'Deploy your own backend to use real agents.';
  static const String demoReplyZh =
      '这是 Relay 演示模式，agent 不会真的运行。部署自己的后端后即可使用真实 agent。';

  static const String _demoWorkdir = '/home/demo/Relay';
  static const String _demoTimestamp = '2026-01-01T00:00:00.000Z';
  static const String _languagePrefsKey = 'relay.language.v1';

  final AppLanguage? language;
  final Duration chunkDelay;
  final int chunkSize;

  final Map<String, Map<String, String>> _settings =
      <String, Map<String, String>>{};
  final Map<String, List<Map<String, Object?>>> _histories =
      <String, List<Map<String, Object?>>>{};
  final Set<StreamController<List<int>>> _openStreams =
      <StreamController<List<int>>>{};
  final Set<Timer> _eventTimers = <Timer>{};
  final Map<String, _ActiveDemoChat> _activeChats = <String, _ActiveDemoChat>{};
  bool _closed = false;

  /// Returns an [http.Client] whose [close] cancels only the chat stream sent
  /// through it, leaving this shared [DemoHttpClient] usable for other calls.
  http.Client createStreamClient() => _DemoStreamClient(this);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('DemoHttpClient is closed.', request.url);
    }

    final String method = request.method.toUpperCase();
    final String path = request.url.path;
    final Map<String, String> query = request.url.queryParameters;

    if (method == 'GET') {
      return _handleGet(path, query, request);
    }
    if (method == 'POST') {
      return _handlePost(path, request);
    }
    return _jsonResponse(
      501,
      const <String, Object?>{'error': 'Not available in demo mode'},
      request: request,
    );
  }

  Future<http.StreamedResponse> _handleGet(
    String path,
    Map<String, String> query,
    http.BaseRequest request,
  ) async {
    switch (path) {
      case '/api/health':
        return _jsonResponse(200, const <String, Object?>{'ok': true});
      case '/api/status':
        return _jsonResponse(200, <String, Object?>{
          'ok': true,
          'defaultAgent': 'claude',
          'workdir': _demoWorkdir,
          'defaultWorkdir': _demoWorkdir,
          'systemUptime': '3d 14h 22m 0s',
          'processUptime': '1h 12m 5s',
          'publicBaseUrl': demoMachineBaseUrl,
        });
      case '/api/diagnostics':
        return _jsonResponse(
          404,
          const <String, Object?>{'error': 'Not available in demo mode'},
        );
      case '/api/agents':
        return _jsonResponse(200, <String, Object?>{
          'defaultAgent': 'claude',
          'agents': _demoAgentsPayload(),
        });
      case '/api/auth/status':
        return _jsonResponse(200, const <String, Object?>{
          'agents': <Map<String, Object?>>[
            <String, Object?>{
              'key': 'claude',
              'label': 'Claude Code',
              'loggedIn': true,
            },
            <String, Object?>{
              'key': 'codex',
              'label': 'Codex',
              'loggedIn': true,
            },
          ],
        });
      case '/api/agent-options':
        final String agentKey = (query['agent'] ?? 'claude').trim();
        final Map<String, Object?>? catalog = _agentOptionsFor(agentKey);
        if (catalog == null) {
          return _jsonResponse(
            400,
            <String, Object?>{'error': 'unknown agent: $agentKey'},
          );
        }
        return _jsonResponse(200, catalog);
      case '/api/agent-settings':
        final String agentKey = _normalizeAgentKey(query['agent']);
        final String sessionId = (query['sessionId'] ?? 'default').trim();
        return _jsonResponse(200, <String, Object?>{
          'ok': true,
          'agent': agentKey,
          'workdir': _demoWorkdir,
          'settings': _settingsFor(agentKey, sessionId),
        });
      case '/api/sessions':
      case '/api/sessions/active':
        final String agentKey = _normalizeAgentKey(query['agent']);
        return _jsonResponse(200, _sessionListPayload(agentKey));
      case '/api/history':
        final String agentKey = _normalizeAgentKey(query['agent']);
        final String sessionId = _normalizeSessionId(query['sessionId']);
        return _jsonResponse(200, <String, Object?>{
          'agent': agentKey,
          'workdir': _demoWorkdir,
          'session': _sessionPayload(sessionId),
          'messages': _historySnapshot(agentKey, sessionId),
          'contextWindow': 200000,
        });
      case '/api/history/search':
        final String rawQuery = (query['q'] ?? '').trim();
        if (rawQuery.isEmpty) {
          return _jsonResponse(
            400,
            const <String, Object?>{'error': 'q is required'},
          );
        }
        final String agentFilter = (query['agent'] ?? '').trim();
        return _jsonResponse(200, <String, Object?>{
          'workdir': _demoWorkdir,
          'query': rawQuery,
          'matches': _searchHistories(rawQuery, agentFilter: agentFilter),
        });
      case '/api/history/export':
        final String agentKey = _normalizeAgentKey(query['agent']);
        final String sessionId = _normalizeSessionId(query['sessionId']);
        return _jsonResponse(200, <String, Object?>{
          'agent': agentKey,
          'session': _sessionPayload(sessionId),
          'fileName': '$agentKey-main.md',
          'markdown': _exportHistoryMarkdown(agentKey, sessionId),
        });
      case '/api/tokens':
        return _jsonResponse(200, const <String, Object?>{
          'tokens': <Object?>[],
        });
      case '/api/machine':
        return _jsonResponse(200, const <String, Object?>{
          'ok': true,
          'hostname': 'demo-machine',
          'version': '0.2.2',
          'cpu': <String, Object?>{
            'model': 'Demo Virtual CPU',
            'cores': 8,
          },
          'memoryBytes': 16 * 1024 * 1024 * 1024,
          'gpus': <String>['Demo Virtual GPU'],
          'disks': <Map<String, Object?>>[
            <String, Object?>{
              'mount': '/',
              'usedBytes': 40 * 1024 * 1024 * 1024,
              'totalBytes': 128 * 1024 * 1024 * 1024,
            },
          ],
          'temperatures': <Map<String, Object?>>[
            <String, Object?>{'key': 'cpu', 'label': 'CPU', 'celsius': 46.0},
          ],
        });
      case '/api/workdir':
        return _jsonResponse(200, const <String, Object?>{
          'dir': _demoWorkdir,
          'defaultDir': _demoWorkdir,
          'busy': false,
        });
      case '/api/workdirs/recent':
        return _jsonResponse(200, const <String, Object?>{
          'workdirs': <String>[_demoWorkdir],
        });
      case '/api/usage':
        return _jsonResponse(200, _usagePayload(query['source']));
      case '/api/quota-schedules':
        return _jsonResponse(200, const <String, Object?>{
          'workdir': _demoWorkdir,
          'schedules': <Object?>[],
        });
      case '/api/groups':
        return _jsonResponse(200, const <String, Object?>{
          'groups': <Object?>[],
        });
      case '/api/events':
        return _openEventsStream(request);
      default:
        return _jsonResponse(
          501,
          const <String, Object?>{'error': 'Not available in demo mode'},
          request: request,
        );
    }
  }

  Future<http.StreamedResponse> _handlePost(
    String path,
    http.BaseRequest request, {
    void Function(String requestId)? onChatRegistered,
    bool Function()? isClientClosed,
  }) async {
    switch (path) {
      case '/api/agent-settings':
        final Map<String, Object?> body = await _decodeBody(request);
        final String agentKey = _normalizeAgentKey(body['agent']?.toString());
        final String sessionId = _normalizeSessionId(
          body['sessionId']?.toString(),
        );
        final Map<String, String> current = Map<String, String>.from(
          _settingsFor(agentKey, sessionId),
        );
        for (final String group in const <String>[
          'model',
          'effort',
          'permission',
          'fast',
        ]) {
          final Object? value = body[group];
          if (value is String && value.trim().isNotEmpty) {
            current[group] = value.trim();
          }
        }
        _settings[_settingsScope(agentKey, sessionId)] = current;
        return _jsonResponse(200, <String, Object?>{
          'ok': true,
          'agent': agentKey,
          'workdir': _demoWorkdir,
          'settings': current,
        });
      case '/api/sessions/active':
        final Map<String, Object?> body = await _decodeBody(request);
        final String agentKey = _normalizeAgentKey(body['agent']?.toString());
        return _jsonResponse(200, _sessionListPayload(agentKey));
      case '/api/session/clear':
        final Map<String, Object?> body = await _decodeBody(request);
        final String rawAgent = (body['agent']?.toString() ?? '').trim();
        final String sessionId = _normalizeSessionId(
          body['sessionId']?.toString(),
        );
        if (rawAgent.isEmpty) {
          if (_activeChats.isNotEmpty) {
            return _jsonResponse(409, const <String, Object?>{
              'error': 'session has a running turn',
              'code': 'SESSION_BUSY',
            });
          }
          final int cleared = _histories.length;
          _histories.clear();
          return _jsonResponse(200, <String, Object?>{
            'ok': true,
            'workdir': _demoWorkdir,
            'cleared': cleared,
          });
        }
        final String agentKey = _normalizeAgentKey(rawAgent);
        final String scope = _settingsScope(agentKey, sessionId);
        if (_hasActiveTurnInScope(agentKey, sessionId)) {
          return _jsonResponse(409, const <String, Object?>{
            'error': 'session has a running turn',
            'code': 'SESSION_BUSY',
          });
        }
        final bool hadHistory = _histories.remove(scope) != null;
        return _jsonResponse(200, <String, Object?>{
          'ok': true,
          'agent': agentKey,
          'workdir': _demoWorkdir,
          'session': _sessionPayload(sessionId),
          'cleared': hadHistory ? 1 : 0,
        });
      case '/api/chat':
        final Map<String, Object?> body = await _decodeBody(request);
        final String prompt = (body['prompt']?.toString() ?? '').trim();
        if (prompt.isEmpty) {
          return _jsonResponse(
            400,
            const <String, Object?>{'error': 'prompt is required'},
          );
        }
        final String agentKey = _normalizeAgentKey(body['agent']?.toString());
        final String sessionId = _normalizeSessionId(
          body['sessionId']?.toString(),
        );
        final bool recordHistory = body['recordHistory'] != false;
        final String requestId =
            (body['requestId']?.toString() ?? '').trim().isEmpty
                ? 'demo.${DateTime.now().microsecondsSinceEpoch}'
                : body['requestId'].toString().trim();
        final bool zh = await _isZh(request);
        if (_closed || isClientClosed?.call() == true) {
          throw http.ClientException('Stream handle closed.', request.url);
        }
        final String replyText = zh ? demoReplyZh : demoReplyEn;

        final String accept = _header(request, 'accept').toLowerCase();
        final bool wantsJson = accept.contains('application/json') &&
            !accept.contains('text/event-stream');
        if (wantsJson) {
          if (recordHistory) {
            _recordUserPrompt(
              agentKey: agentKey,
              sessionId: sessionId,
              requestId: requestId,
              prompt: prompt,
            );
            _recordAssistantTurn(
              agentKey: agentKey,
              sessionId: sessionId,
              requestId: requestId,
              content: replyText,
              streaming: false,
            );
          }
          return _jsonResponse(
            200,
            _chatReplyJson(
              requestId: requestId,
              agentKey: agentKey,
              sessionId: sessionId,
              content: replyText,
            ),
          );
        }

        if (recordHistory) {
          _recordUserPrompt(
            agentKey: agentKey,
            sessionId: sessionId,
            requestId: requestId,
            prompt: prompt,
          );
          _recordAssistantTurn(
            agentKey: agentKey,
            sessionId: sessionId,
            requestId: requestId,
            content: '',
            streaming: true,
          );
        }
        onChatRegistered?.call(requestId);
        return _streamChatReply(
          request: request,
          requestId: requestId,
          agentKey: agentKey,
          sessionId: sessionId,
          replyText: replyText,
          recordHistory: recordHistory,
        );
      case '/api/chat/cancel':
        final Map<String, Object?> body = await _decodeBody(request);
        final String requestId = (body['requestId']?.toString() ?? '').trim();
        final _ActiveDemoChat? chat = _activeChats.remove(requestId);
        if (chat == null) {
          return _jsonResponse(404, const <String, Object?>{
            'error': 'request not found',
            'code': 'REQUEST_NOT_FOUND',
          });
        }
        _finalizeCancelledChat(chat);
        chat.cancel(emitCancelledEvent: true);
        return _jsonResponse(200, <String, Object?>{
          'ok': true,
          'requestId': requestId,
        });
      default:
        if (request is http.StreamedRequest) {
          await request.finalize().drain<void>();
        }
        return _jsonResponse(
          501,
          const <String, Object?>{'error': 'Not available in demo mode'},
          request: request,
        );
    }
  }

  Future<http.StreamedResponse> _sendFromStreamClient(
    http.BaseRequest request, {
    required void Function(String requestId) onChatRegistered,
    required bool Function() isClientClosed,
  }) async {
    if (_closed || isClientClosed()) {
      throw http.ClientException('DemoHttpClient is closed.', request.url);
    }
    final String method = request.method.toUpperCase();
    if (method == 'POST') {
      return _handlePost(
        request.url.path,
        request,
        onChatRegistered: onChatRegistered,
        isClientClosed: isClientClosed,
      );
    }
    return send(request);
  }

  void _abortStreamRequest(String requestId) {
    final _ActiveDemoChat? chat = _activeChats.remove(requestId);
    if (chat == null) return;
    _finalizeCancelledChat(chat);
    chat.cancel(emitCancelledEvent: false);
  }

  http.StreamedResponse _openEventsStream(http.BaseRequest request) {
    late final StreamController<List<int>> controller;
    Timer? heartbeat;
    controller = StreamController<List<int>>(
      // `async` returns a zone-scoped Future from StreamSubscription.cancel()
      // rather than Dart's root-zone `_nullFuture`, which stalls FakeAsync tests.
      onCancel: () async {
        if (heartbeat != null) {
          heartbeat.cancel();
          _eventTimers.remove(heartbeat);
        }
        _openStreams.remove(controller);
        if (!controller.isClosed) unawaited(controller.close());
      },
    );
    _openStreams.add(controller);
    controller.add(utf8.encode('event: ready\ndata: {"ok":true}\n\n'));
    heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_closed || controller.isClosed) {
        heartbeat?.cancel();
        _eventTimers.remove(heartbeat);
        return;
      }
      controller.add(
        utf8.encode(
          'event: heartbeat\ndata: ${jsonEncode(<String, Object?>{
                'at': DateTime.now().toUtc().toIso8601String(),
              })}\n\n',
        ),
      );
    });
    _eventTimers.add(heartbeat);
    return http.StreamedResponse(
      controller.stream,
      200,
      request: request,
      headers: const <String, String>{
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache',
      },
    );
  }

  http.StreamedResponse _streamChatReply({
    required http.BaseRequest request,
    required String requestId,
    required String agentKey,
    required String sessionId,
    required String replyText,
    required bool recordHistory,
  }) {
    late final StreamController<List<int>> controller;
    late final _ActiveDemoChat active;
    controller = StreamController<List<int>>(
      onCancel: () async {
        _openStreams.remove(controller);
        _activeChats.remove(requestId);
        _finalizeCancelledChat(active);
        active.aborted = true;
      },
    );
    active = _ActiveDemoChat(
      controller: controller,
      agentKey: agentKey,
      sessionId: sessionId,
      requestId: requestId,
      recordHistory: recordHistory,
    );
    _openStreams.add(controller);
    _activeChats[requestId] = active;

    unawaited(_emitDemoChat(active, replyText));

    return http.StreamedResponse(
      controller.stream,
      200,
      request: request,
      headers: const <String, String>{
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache',
      },
    );
  }

  Future<void> _emitDemoChat(_ActiveDemoChat chat, String replyText) async {
    final StreamController<List<int>> controller = chat.controller;
    void writeEvent(String type, Map<String, Object?> payload) {
      if (chat.aborted || controller.isClosed) return;
      controller.add(
        utf8.encode('event: $type\ndata: ${jsonEncode(payload)}\n\n'),
      );
    }

    try {
      writeEvent('ready', <String, Object?>{
        'ok': true,
        'requestId': chat.requestId,
      });

      final Map<String, Object?> agent = _agentSummary(chat.agentKey);
      final Map<String, Object?> session = _sessionPayload(chat.sessionId);

      for (final String chunk in _chunkText(replyText, chunkSize)) {
        if (chunkDelay > Duration.zero) {
          await Future<void>.delayed(chunkDelay);
        }
        if (chat.aborted || _closed || controller.isClosed) return;
        chat.accumulated.write(chunk);
        if (chat.recordHistory) {
          _recordAssistantTurn(
            agentKey: chat.agentKey,
            sessionId: chat.sessionId,
            requestId: chat.requestId,
            content: chat.accumulated.toString(),
            streaming: true,
          );
        }
        writeEvent('agent_delta', <String, Object?>{
          'requestId': chat.requestId,
          'agent': agent,
          'session': session,
          'text': chunk,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        });
      }

      if (chat.aborted || _closed || controller.isClosed) return;
      if (chat.recordHistory) {
        _recordAssistantTurn(
          agentKey: chat.agentKey,
          sessionId: chat.sessionId,
          requestId: chat.requestId,
          content: replyText,
          streaming: false,
        );
      }
      writeEvent(
        'agent_done',
        _chatReplyJson(
          requestId: chat.requestId,
          agentKey: chat.agentKey,
          sessionId: chat.sessionId,
          content: replyText,
        ),
      );
    } finally {
      _activeChats.remove(chat.requestId);
      _openStreams.remove(controller);
      if (!controller.isClosed) await controller.close();
    }
  }

  Map<String, Object?> _chatReplyJson({
    required String requestId,
    required String agentKey,
    required String sessionId,
    required String content,
  }) {
    final String nowIso = DateTime.now().toUtc().toIso8601String();
    return <String, Object?>{
      'requestId': requestId,
      'agent': _agentSummary(agentKey),
      'session': <String, Object?>{
        'id': sessionId.isEmpty ? 'default' : sessionId,
        'name': 'Main',
      },
      'message': <String, Object?>{
        'role': 'assistant',
        'content': content,
        'segments': <Map<String, Object?>>[
          <String, Object?>{'ts': nowIso, 'text': content},
        ],
        'context': const <String, Object?>{'used': 120, 'size': 200000},
        'createdAt': nowIso,
      },
    };
  }

  Future<bool> _isZh(http.BaseRequest request) async {
    if (language != null) return language == AppLanguage.zh;
    final String header = _header(request, 'accept-language').toLowerCase();
    if (header.isNotEmpty) return header.startsWith('zh');
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getString(_languagePrefsKey) == 'zh';
    } catch (_) {
      return false;
    }
  }

  String _header(http.BaseRequest request, String name) {
    final String lower = name.toLowerCase();
    for (final MapEntry<String, String> entry in request.headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return '';
  }

  Future<Map<String, Object?>> _decodeBody(http.BaseRequest request) async {
    final String raw = request is http.Request
        ? request.body
        : utf8.decode(await request.finalize().toBytes());
    if (raw.trim().isEmpty) return const <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Ignore malformed request body and treat as empty.
    }
    return const <String, Object?>{};
  }

  http.StreamedResponse _jsonResponse(
    int statusCode,
    Map<String, Object?> payload, {
    http.BaseRequest? request,
  }) {
    final List<int> bytes = utf8.encode(jsonEncode(payload));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      statusCode,
      contentLength: bytes.length,
      request: request,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );
  }

  String _normalizeAgentKey(String? raw) {
    final String trimmed = (raw ?? '').trim();
    return trimmed == 'codex' ? 'codex' : 'claude';
  }

  String _normalizeSessionId(String? raw) {
    final String trimmed = (raw ?? '').trim();
    return trimmed.isEmpty ? 'default' : trimmed;
  }

  Map<String, Object?> _sessionPayload(String sessionId) {
    final String clean = _normalizeSessionId(sessionId);
    return <String, Object?>{
      'id': clean,
      'name': clean == 'default' ? 'Main' : clean,
    };
  }

  String _settingsScope(String agentKey, String sessionId) {
    final String cleanSession = _normalizeSessionId(sessionId);
    return '$agentKey:$cleanSession';
  }

  bool _hasActiveTurnInScope(String agentKey, String sessionId) {
    final String cleanSession = _normalizeSessionId(sessionId);
    return _activeChats.values.any(
      (_ActiveDemoChat chat) =>
          chat.agentKey == agentKey &&
          _normalizeSessionId(chat.sessionId) == cleanSession,
    );
  }

  void _recordUserPrompt({
    required String agentKey,
    required String sessionId,
    required String requestId,
    required String prompt,
  }) {
    final String scope = _settingsScope(agentKey, sessionId);
    final List<Map<String, Object?>> list = _histories.putIfAbsent(
      scope,
      () => <Map<String, Object?>>[],
    );
    final String nowIso = DateTime.now().toUtc().toIso8601String();
    final Map<String, Object?> agent = _agentSummary(agentKey);
    final Map<String, Object?> session = _sessionPayload(sessionId);
    _upsertHistoryMessage(list, <String, Object?>{
      'id': '$requestId:user',
      'role': 'user',
      'content': prompt,
      'agent': agentKey,
      'createdAt': nowIso,
      'metadata': <String, Object?>{
        'requestId': requestId,
        'agentKey': agentKey,
        'agentLabel': agent['label'],
        'sessionId': session['id'],
        'sessionName': session['name'],
      },
    });
  }

  void _recordAssistantTurn({
    required String agentKey,
    required String sessionId,
    required String requestId,
    required String content,
    required bool streaming,
    bool cancelled = false,
  }) {
    final String scope = _settingsScope(agentKey, sessionId);
    final List<Map<String, Object?>> list = _histories.putIfAbsent(
      scope,
      () => <Map<String, Object?>>[],
    );
    final String nowIso = DateTime.now().toUtc().toIso8601String();
    final Map<String, Object?> agent = _agentSummary(agentKey);
    final Map<String, Object?> session = _sessionPayload(sessionId);
    final String existingCreatedAt = list
            .where(
              (Map<String, Object?> m) => m['id'] == '$requestId:assistant',
            )
            .firstOrNull?['createdAt'] as String? ??
        nowIso;
    _upsertHistoryMessage(list, <String, Object?>{
      'id': '$requestId:assistant',
      'role': 'assistant',
      'content': content,
      'agent': agentKey,
      'createdAt': existingCreatedAt,
      'updatedAt': nowIso,
      'metadata': <String, Object?>{
        'requestId': requestId,
        'agentKey': agentKey,
        'agentLabel': agent['label'],
        'sessionId': session['id'],
        'sessionName': session['name'],
        'streaming': streaming,
        'awaitingFirstToken': streaming && content.isEmpty,
        if (cancelled) 'cancelled': true,
        if (!streaming && !cancelled) ...<String, Object?>{
          'segments': <Map<String, Object?>>[
            <String, Object?>{'ts': nowIso, 'text': content},
          ],
          'context': const <String, Object?>{'used': 120, 'size': 200000},
        },
      },
    });
  }

  void _finalizeCancelledChat(_ActiveDemoChat chat) {
    if (!chat.recordHistory || chat.aborted) return;
    _recordAssistantTurn(
      agentKey: chat.agentKey,
      sessionId: chat.sessionId,
      requestId: chat.requestId,
      content: chat.accumulated.toString(),
      streaming: false,
      cancelled: true,
    );
  }

  void _upsertHistoryMessage(
    List<Map<String, Object?>> list,
    Map<String, Object?> message,
  ) {
    final Object? id = message['id'];
    final int index =
        list.indexWhere((Map<String, Object?> item) => item['id'] == id);
    if (index == -1) {
      list.add(message);
    } else {
      list[index] = message;
    }
  }

  List<Map<String, Object?>> _historySnapshot(
    String agentKey,
    String sessionId,
  ) {
    final List<Map<String, Object?>>? list =
        _histories[_settingsScope(agentKey, sessionId)];
    if (list == null) return const <Map<String, Object?>>[];
    return list
        .map(
          (Map<String, Object?> m) => <String, Object?>{
            ...m,
            if (m['metadata'] is Map)
              'metadata': Map<String, Object?>.from(m['metadata']! as Map),
          },
        )
        .toList(growable: false);
  }

  List<Map<String, Object?>> _searchHistories(
    String query, {
    String agentFilter = '',
  }) {
    final String needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const <Map<String, Object?>>[];
    final List<Map<String, Object?>> matches = <Map<String, Object?>>[];
    for (final MapEntry<String, List<Map<String, Object?>>> entry
        in _histories.entries) {
      final List<String> parts = entry.key.split(':');
      final String agentKey = parts.first;
      final String sessionId = parts.length > 1 ? parts[1] : 'default';
      if (agentFilter.isNotEmpty && agentKey != agentFilter) continue;
      final String sessionName = _sessionPayload(sessionId)['name']! as String;
      for (final Map<String, Object?> message in entry.value) {
        final String content = message['content'] as String? ?? '';
        final int hitIndex = content.toLowerCase().indexOf(needle);
        if (hitIndex == -1) continue;
        final String compact = content.replaceAll(RegExp(r'\s+'), ' ').trim();
        final int compactIndex = compact.toLowerCase().indexOf(needle);
        final int start = compactIndex <= 80 ? 0 : compactIndex - 80;
        final int end =
            (compactIndex == -1 ? 0 : compactIndex) + needle.length + 120;
        final int clampedEnd = end > compact.length ? compact.length : end;
        final String snippet =
            '${start > 0 ? '...' : ''}${compact.substring(start, clampedEnd)}${clampedEnd < compact.length ? '...' : ''}';
        matches.add(<String, Object?>{
          'agentKey': agentKey,
          'sessionId': sessionId,
          'sessionName': sessionName,
          'snippet': snippet,
          'messageId': message['id'] as String? ?? '',
        });
      }
    }
    return matches;
  }

  String _exportHistoryMarkdown(String agentKey, String sessionId) {
    final String agentLabel = _agentSummary(agentKey)['label']! as String;
    final String sessionName = _sessionPayload(sessionId)['name']! as String;
    final String exportedAt = DateTime.now().toUtc().toIso8601String();
    final List<String> lines = <String>[
      '# Relay Conversation Export',
      '',
      '- Agent: $agentLabel',
      '- Session: $sessionName',
      '- Exported: $exportedAt',
      '',
    ];
    for (final Map<String, Object?> message
        in _histories[_settingsScope(agentKey, sessionId)] ??
            const <Map<String, Object?>>[]) {
      final String role = message['role'] as String? ?? 'message';
      final String title =
          '${role.substring(0, 1).toUpperCase()}${role.substring(1)}';
      final String createdAt = message['createdAt'] as String? ?? '';
      lines.add('## $title${createdAt.isEmpty ? '' : ' - $createdAt'}');
      lines.add('');
      final String content = (message['content'] as String? ?? '').trim();
      lines.add(content.isEmpty ? '_No content_' : content);
      lines.add('');
    }
    return '${lines.join('\n').trim()}\n';
  }

  Map<String, String> _settingsFor(String agentKey, String sessionId) {
    final String scope = _settingsScope(agentKey, sessionId);
    return _settings[scope] ?? _defaultSettingsFor(agentKey);
  }

  Map<String, String> _defaultSettingsFor(String agentKey) {
    if (agentKey == 'codex') {
      return const <String, String>{
        'model': 'gpt-5.5',
        'effort': 'medium',
        'permission': 'workspace-write',
        'fast': 'off',
      };
    }
    return const <String, String>{
      'model': 'claude-opus-4-8',
      'effort': 'high',
      'permission': 'acceptEdits',
      'fast': 'off',
    };
  }

  Map<String, Object?> _agentSummary(String agentKey) {
    return agentKey == 'codex'
        ? const <String, Object?>{'key': 'codex', 'label': 'Codex'}
        : const <String, Object?>{'key': 'claude', 'label': 'Claude Code'};
  }

  List<Map<String, Object?>> _demoAgentsPayload() {
    return const <Map<String, Object?>>[
      <String, Object?>{
        'key': 'claude',
        'label': 'Claude Code',
        'description': 'Anthropic Claude Code CLI',
        'installed': true,
        'authed': true,
        'authKind': 'oauth',
        'usable': true,
      },
      <String, Object?>{
        'key': 'codex',
        'label': 'Codex',
        'description': 'OpenAI Codex CLI',
        'installed': true,
        'authed': true,
        'authKind': 'oauth',
        'usable': true,
      },
    ];
  }

  Map<String, Object?> _sessionListPayload(String agentKey) {
    return <String, Object?>{
      'ok': true,
      'agent': _agentSummary(agentKey),
      'workdir': _demoWorkdir,
      'activeSessionId': 'default',
      'sessions': const <Map<String, Object?>>[
        <String, Object?>{
          'id': 'default',
          'name': 'Main',
          'createdAt': _demoTimestamp,
          'updatedAt': _demoTimestamp,
        },
      ],
    };
  }

  Map<String, Object?>? _agentOptionsFor(String agentKey) {
    if (agentKey == 'claude') {
      return const <String, Object?>{
        'ok': true,
        'agent': 'claude',
        'defaults': <String, String>{
          'model': 'claude-opus-4-8',
          'effort': 'high',
          'permission': 'acceptEdits',
          'fast': 'off',
        },
        'supports': <String, bool>{
          'model': true,
          'effort': true,
          'permission': true,
          'fast': true,
        },
        'model': <Map<String, Object?>>[
          <String, Object?>{'id': 'claude-opus-4-8', 'label': 'Opus 4.8'},
          <String, Object?>{'id': 'claude-sonnet-4-6', 'label': 'Sonnet 4.6'},
          <String, Object?>{'id': 'claude-haiku-4-5', 'label': 'Haiku 4.5'},
        ],
        'effort': <Map<String, Object?>>[
          <String, Object?>{'id': 'low', 'label': 'Low'},
          <String, Object?>{'id': 'medium', 'label': 'Medium'},
          <String, Object?>{'id': 'high', 'label': 'High'},
          <String, Object?>{'id': 'xhigh', 'label': 'Extra high'},
          <String, Object?>{'id': 'max', 'label': 'Max'},
        ],
        'effortByModel': <String, Object?>{},
        'defaultEffortByModel': <String, Object?>{},
        'permission': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'bypass',
            'label': 'Bypass (full auto)',
            'description': 'Skip all permission checks.',
          },
          <String, Object?>{
            'id': 'acceptEdits',
            'label': 'Auto-accept edits',
            'description': 'Auto-approve file edits.',
          },
          <String, Object?>{
            'id': 'plan',
            'label': 'Plan only (read-only)',
            'description': 'Read and plan, but make no changes.',
          },
        ],
        'fast': <Map<String, Object?>>[
          <String, Object?>{'id': 'off', 'label': 'Off'},
          <String, Object?>{'id': 'on', 'label': 'On'},
        ],
      };
    }
    if (agentKey == 'codex') {
      return const <String, Object?>{
        'ok': true,
        'agent': 'codex',
        'defaults': <String, String>{
          'model': 'gpt-5.5',
          'effort': 'medium',
          'permission': 'workspace-write',
          'fast': 'off',
        },
        'supports': <String, bool>{
          'model': true,
          'effort': true,
          'permission': true,
          'fast': true,
        },
        'model': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'gpt-5.5',
            'label': 'GPT-5.5 (recommended)',
          },
          <String, Object?>{'id': 'gpt-5.4', 'label': 'GPT-5.4'},
          <String, Object?>{
            'id': 'gpt-5.4-mini',
            'label': 'GPT-5.4 Mini (fast)',
          },
        ],
        'effort': <Map<String, Object?>>[
          <String, Object?>{'id': 'low', 'label': 'Low'},
          <String, Object?>{'id': 'medium', 'label': 'Medium'},
          <String, Object?>{'id': 'high', 'label': 'High'},
          <String, Object?>{'id': 'xhigh', 'label': 'Extra high'},
        ],
        'effortByModel': <String, Object?>{},
        'defaultEffortByModel': <String, Object?>{},
        'permission': <Map<String, Object?>>[
          <String, Object?>{
            'id': 'workspace-write',
            'label': 'Workspace write',
            'description': 'Edit inside the workspace.',
          },
          <String, Object?>{
            'id': 'read-only',
            'label': 'Read only',
            'description': 'Inspect files but make no changes.',
          },
          <String, Object?>{
            'id': 'full-access',
            'label': 'Full access',
            'description': 'No sandbox restrictions.',
          },
        ],
        'fast': <Map<String, Object?>>[
          <String, Object?>{'id': 'off', 'label': 'Off'},
          <String, Object?>{'id': 'on', 'label': 'On'},
        ],
      };
    }
    return null;
  }

  Map<String, Object?> _usagePayload(String? source) {
    final DateTime now = DateTime.now().toUtc();
    final String fiveHourReset =
        now.add(const Duration(hours: 3)).toIso8601String();
    final String weeklyReset =
        now.add(const Duration(days: 4)).toIso8601String();
    final Map<String, Map<String, Object?>> all =
        <String, Map<String, Object?>>{
      'claude': <String, Object?>{
        'key': 'claude',
        'label': 'Claude Code',
        'available': true,
        'stale': false,
        'quotas': <Map<String, Object?>>[
          <String, Object?>{
            'key': 'five_hour',
            'label': '5 hours',
            'remainingPercent': 100,
            'resetsAt': fiveHourReset,
          },
          <String, Object?>{
            'key': 'seven_day',
            'label': 'This week',
            'remainingPercent': 100,
            'resetsAt': weeklyReset,
          },
        ],
      },
      'codex': <String, Object?>{
        'key': 'codex',
        'label': 'Codex',
        'available': true,
        'stale': false,
        'quotas': <Map<String, Object?>>[
          <String, Object?>{
            'key': 'five_hour',
            'label': '5 hours',
            'remainingPercent': 100,
            'resetsAt': fiveHourReset,
          },
          <String, Object?>{
            'key': 'seven_day',
            'label': 'This week',
            'remainingPercent': 100,
            'resetsAt': weeklyReset,
          },
        ],
      },
      'cursor': const <String, Object?>{
        'key': 'cursor',
        'label': 'Cursor',
        'available': false,
        'stale': false,
        'unavailableReason': 'Not available in demo mode',
        'quotas': <Object?>[],
      },
      'agy': const <String, Object?>{
        'key': 'agy',
        'label': 'Antigravity',
        'available': false,
        'stale': false,
        'unavailableReason': 'Not available in demo mode',
        'quotas': <Object?>[],
      },
    };
    final List<Map<String, Object?>> agents =
        source != null && source.isNotEmpty
            ? <Map<String, Object?>>[
                all[source] ??
                    <String, Object?>{
                      'key': source,
                      'label': source,
                      'available': false,
                      'stale': false,
                      'unavailableReason': 'Not available in demo mode',
                      'quotas': <Object?>[],
                    },
              ]
            : <Map<String, Object?>>[all['claude']!, all['codex']!];
    return <String, Object?>{
      'createdAt': now.toIso8601String(),
      'mode': 'remaining',
      'hasStale': false,
      'agents': agents,
    };
  }

  List<String> _chunkText(String text, int size) {
    final int safeSize = size < 1 ? 1 : size;
    final List<int> runes = text.runes.toList(growable: false);
    final List<String> chunks = <String>[];
    for (int i = 0; i < runes.length; i += safeSize) {
      final int end = i + safeSize > runes.length ? runes.length : i + safeSize;
      chunks.add(String.fromCharCodes(runes.sublist(i, end)));
    }
    return chunks;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final Timer timer in _eventTimers.toList()) {
      timer.cancel();
    }
    _eventTimers.clear();
    for (final _ActiveDemoChat chat in _activeChats.values.toList()) {
      _finalizeCancelledChat(chat);
      chat.cancel(emitCancelledEvent: false);
    }
    _activeChats.clear();
    for (final StreamController<List<int>> stream in _openStreams.toList()) {
      if (!stream.isClosed) unawaited(stream.close());
    }
    _openStreams.clear();
  }
}

class _ActiveDemoChat {
  _ActiveDemoChat({
    required this.controller,
    required this.agentKey,
    required this.sessionId,
    required this.requestId,
    required this.recordHistory,
  });

  final StreamController<List<int>> controller;
  final String agentKey;
  final String sessionId;
  final String requestId;
  final bool recordHistory;
  final StringBuffer accumulated = StringBuffer();
  bool aborted = false;

  void cancel({required bool emitCancelledEvent}) {
    if (aborted) return;
    aborted = true;
    if (emitCancelledEvent && !controller.isClosed) {
      controller.add(
        utf8.encode(
          'event: agent_cancelled\ndata: ${jsonEncode(<String, Object?>{
                'requestId': requestId,
                'agent': agentKey == 'codex'
                    ? const <String, Object?>{'key': 'codex', 'label': 'Codex'}
                    : const <String, Object?>{
                        'key': 'claude',
                        'label': 'Claude Code',
                      },
                'session': <String, Object?>{
                  'id': sessionId.isEmpty ? 'default' : sessionId,
                  'name': 'Main',
                },
                'createdAt': DateTime.now().toUtc().toIso8601String(),
              })}\n\n',
        ),
      );
    }
    if (!controller.isClosed) unawaited(controller.close());
  }
}

class _DemoStreamClient extends http.BaseClient {
  _DemoStreamClient(this._demo);

  final DemoHttpClient _demo;
  String? _requestId;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('Stream handle closed.', request.url);
    }
    return _demo._sendFromStreamClient(
      request,
      onChatRegistered: (String requestId) {
        _requestId = requestId;
      },
      isClientClosed: () => _closed,
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    final String? id = _requestId;
    if (id != null) {
      _demo._abortStreamRequest(id);
    }
  }
}
