import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/agent_options.dart';
import '../models/agent_session.dart';
import '../models/backend_status.dart';
import '../models/chat_history.dart';
import '../models/chat_message.dart';
import '../models/cli_agent.dart';
import '../models/filesystem.dart';
import '../models/group.dart';
import '../models/machine_credential.dart';
import '../models/usage.dart';
import '../storage/device_id_store.dart';
import '../storage/machine_credentials_store.dart';
import '../storage/workdir_store.dart';
import 'api_transport.dart';
import 'sse_codec.dart';

export '../models/agent_session.dart' show AgentSessionList;
export '../models/backend_status.dart';
export '../models/chat_history.dart';
export '../models/filesystem.dart';
export '../models/usage.dart';
export 'api_transport.dart' show BackendException;
export 'sse_codec.dart' show BackendEvent;

ChatHistory _decodeHistory(String body) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw BackendException('Backend returned non-JSON content.');
  }
  if (decoded is! Map) {
    throw BackendException('历史响应格式不正确。');
  }
  return ChatHistory.fromJson(decoded.cast<String, Object?>());
}

List<MessageSegment> _segmentsFromMessage(Map<String, Object?> message) {
  final Object? raw = message['segments'];
  if (raw is! List) return const <MessageSegment>[];
  return raw
      .whereType<Map>()
      .map((Map e) => MessageSegment.fromJson(e.cast<String, Object?>()))
      .toList(growable: false);
}

class ChatStreamHandle {
  ChatStreamHandle({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  bool _closed = false;

  bool get closed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}

class BackendClient {
  BackendClient({
    MachineCredentialsStore? credentialsStore,
    DeviceIdStore? deviceIdStore,
    WorkdirStore? workdirStore,
    http.Client? httpClient,
  }) : _transport = ApiTransport(
          credentialsStore: credentialsStore,
          deviceIdStore: deviceIdStore,
          workdirStore: workdirStore,
          httpClient: httpClient,
        );

  final ApiTransport _transport;
  http.Client get _httpClient => _transport.httpClient;

  Future<void> close() async {
    _transport.close();
  }

  Future<bool> health({Duration timeout = const Duration(seconds: 20)}) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/health',
      timeout: timeout,
    );
    return decoded is Map && decoded['ok'] == true;
  }

  Future<bool> healthFor(
    MachineCredential credential, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Object? decoded = await _requestJsonWithCredential(
      credential,
      'GET',
      '/api/health',
      timeout: timeout,
    );
    return decoded is Map && decoded['ok'] == true;
  }

  Future<Uri> terminalWebSocketUri({
    required int cols,
    required int rows,
  }) async {
    final MachineCredential credential = await _requireCredential();
    final Object? decoded = await _requestJson(
      'POST',
      '/api/terminal/ticket',
      body: <String, Object?>{'cols': cols, 'rows': rows},
      timeout: const Duration(seconds: 15),
    );
    if (decoded is! Map || decoded['ticket'] is! String) {
      throw BackendException('Invalid SSH terminal ticket response.');
    }
    final String ticket = (decoded['ticket'] as String).trim();
    if (ticket.isEmpty) {
      throw BackendException('The SSH terminal ticket is empty.');
    }
    final Uri endpoint = _uri(credential, '/api/terminal/connect');
    return endpoint.replace(
      scheme: endpoint.scheme == 'https' ? 'wss' : 'ws',
      queryParameters: <String, String>{'ticket': ticket},
    );
  }

  Future<BackendStatus> status({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/status',
      timeout: timeout,
    );
    if (decoded is! Map) {
      throw BackendException('Invalid backend status response.');
    }
    return BackendStatus.fromJson(decoded.cast<String, Object?>());
  }

  Future<BackendDiagnostics> diagnostics({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/diagnostics',
      timeout: timeout,
    );
    if (decoded is! Map) {
      throw BackendException('Invalid backend diagnostics response.');
    }
    return BackendDiagnostics.fromJson(decoded.cast<String, Object?>());
  }

  Future<MachineInfo> machineInfo() async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/machine',
      timeout: const Duration(seconds: 8),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid machine info response.');
    }
    return MachineInfo.fromJson(decoded.cast<String, Object?>());
  }

  Future<List<DeviceToken>> deviceTokens() async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/tokens',
      timeout: const Duration(seconds: 20),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid token list response.');
    }
    final List<Object?> raw = decoded['tokens'] is List
        ? (decoded['tokens'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map((Map item) => DeviceToken.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
  }

  Future<void> revokeDeviceToken(String id) async {
    await _requestJson(
      'POST',
      '/api/tokens/${Uri.encodeComponent(id)}/revoke',
      timeout: const Duration(seconds: 20),
    );
  }

  Future<void> deleteDeviceToken(String id) async {
    await _requestJson(
      'POST',
      '/api/tokens/${Uri.encodeComponent(id)}/delete',
      timeout: const Duration(seconds: 20),
    );
  }

  Future<PushConfig> pushConfig() async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/push/config',
      timeout: const Duration(seconds: 15),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid push config response.');
    }
    return PushConfig.fromJson(decoded.cast<String, Object?>());
  }

  Future<void> subscribePush(
    String subscriptionJson,
    String lang, {
    required bool quotaPushEnabled,
    required bool taskPushEnabled,
  }) async {
    final Object? subscription = jsonDecode(subscriptionJson);
    await _requestJson(
      'POST',
      '/api/push/subscribe',
      body: <String, Object?>{
        'subscription': subscription,
        'lang': lang,
        'quota': quotaPushEnabled,
        'task': taskPushEnabled,
      },
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> registerFcmToken(
    String token,
    String lang, {
    required bool quotaPushEnabled,
    required bool taskPushEnabled,
  }) async {
    await _requestJson(
      'POST',
      '/api/push/fcm/register',
      body: <String, Object?>{
        'token': token,
        'lang': lang,
        'quota': quotaPushEnabled,
        'task': taskPushEnabled,
      },
      timeout: const Duration(seconds: 15),
    );
  }

  Future<void> unregisterFcmToken(String token) async {
    await _requestJson(
      'POST',
      '/api/push/fcm/unregister',
      body: <String, Object?>{'token': token},
      timeout: const Duration(seconds: 15),
    );
  }

  Future<ChatReply> sendMessage({
    required String agentKey,
    required String sessionId,
    required String prompt,
    required String requestId,
    void Function(BackendEvent event)? onEvent,
    ChatStreamHandle? streamHandle,
    void Function()? onStreamStarted,
  }) async {
    if (onEvent != null) {
      return _sendMessageStreamed(
        agentKey: agentKey,
        sessionId: sessionId,
        prompt: prompt,
        requestId: requestId,
        onEvent: onEvent,
        streamHandle: streamHandle,
        onStreamStarted: onStreamStarted,
      );
    }
    final Object? decoded = await _requestJson(
      'POST',
      '/api/chat',
      body: <String, Object?>{
        'agent': agentKey,
        'sessionId': sessionId,
        'prompt': prompt,
        'requestId': requestId,
      },
      timeout: const Duration(minutes: 65),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid backend chat response.');
    }
    final Map<String, Object?> json = decoded.cast<String, Object?>();
    final Map<String, Object?> agent =
        (json['agent'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final Map<String, Object?> message =
        (json['message'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    return ChatReply(
      requestId: json['requestId'] as String? ?? requestId,
      agentKey: agent['key'] as String? ?? agentKey,
      agentLabel: agent['label'] as String? ?? agentKey,
      content: message['content'] as String? ?? '',
      segments: _segmentsFromMessage(message),
      context: (message['context'] as Map?)?.cast<String, Object?>(),
    );
  }

  /// Returns the context size the agent reported after compacting, if any.
  Future<Map<String, Object?>?> compressConversation({
    required String agentKey,
    required String sessionId,
    required String requestId,
  }) async {
    final Object? json = await _requestJson(
      'POST',
      '/api/chat',
      body: <String, Object?>{
        'agent': agentKey,
        'sessionId': sessionId,
        'prompt': '/compact',
        'requestId': requestId,
        'recordHistory': false,
      },
      timeout: const Duration(minutes: 65),
    );
    final Object? message = json is Map ? json['message'] : null;
    return message is Map
        ? (message['context'] as Map?)?.cast<String, Object?>()
        : null;
  }

  Future<ChatReply> _sendMessageStreamed({
    required String agentKey,
    required String sessionId,
    required String prompt,
    required String requestId,
    required void Function(BackendEvent event) onEvent,
    ChatStreamHandle? streamHandle,
    void Function()? onStreamStarted,
    String path = '/api/chat',
  }) async {
    final ChatStreamHandle handle = streamHandle ?? ChatStreamHandle();
    final MachineCredential credential = await _requireCredential();
    final http.Request request = http.Request(
      'POST',
      _uri(credential, path),
    );
    request.headers.addAll(
      await _headers(credential, accept: 'text/event-stream'),
    );
    request.body = jsonEncode(<String, Object?>{
      'agent': agentKey,
      'sessionId': sessionId,
      'prompt': prompt,
      'requestId': requestId,
    });

    try {
      final http.StreamedResponse response = await handle._client
          .send(request)
          .timeout(const Duration(minutes: 65));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final String text = await response.stream.bytesToString();
        throw _exceptionFor(response.statusCode, text);
      }
      onStreamStarted?.call();

      ChatReply? reply;
      BackendException? streamError;
      try {
        await for (final BackendEvent event in decodeSse(
          response.stream,
        ).timeout(const Duration(minutes: 65))) {
          if (event.type == 'ready' || event.type == 'heartbeat') continue;
          onEvent(event);
          if (event.type == 'agent_done') {
            reply = _chatReplyFromStreamDone(event.data, requestId, agentKey);
          } else if (event.type == 'agent_cancelled') {
            streamError = BackendException(
              'request cancelled',
              status: 499,
              code: 'AGENT_CANCELLED',
            );
          } else if (event.type == 'agent_error') {
            final String? code = event.data['code'] as String?;
            streamError = BackendException(
              event.data['error'] as String? ?? 'Agent stream failed.',
              status: code == 'NOT_LOGGED_IN' ? 424 : 500,
              code: code,
            );
          }
        }
      } on http.ClientException {
        // The app was backgrounded/closed and the OS tore down the socket while
        // the backend keeps running the turn. A distinct code lets the caller
        // reattach to the still-running turn instead of marking it failed.
        throw BackendException(
          'Lost the connection to the agent stream.',
          code: 'STREAM_DISCONNECTED',
        );
      } on TimeoutException {
        throw BackendException(
          'The agent stream stalled.',
          code: 'STREAM_DISCONNECTED',
        );
      }
      if (streamError != null) throw streamError;
      if (reply == null) {
        // The stream ended without a terminal agent_done — the turn may still be
        // running on the backend. A distinct code lets the caller reattach.
        throw BackendException(
          'Agent stream ended without a final response.',
          code: 'STREAM_INCOMPLETE',
        );
      }
      return reply;
    } finally {
      handle.close();
    }
  }

  Future<void> cancelMessage(String requestId) async {
    await _requestJson(
      'POST',
      '/api/chat/cancel',
      body: <String, Object?>{'requestId': requestId},
      timeout: const Duration(seconds: 10),
    );
  }

  Future<UsageReport> usageReport({String? source}) async {
    final Object? decoded = await _requestJson(
      'GET',
      source == null
          ? '/api/usage'
          : '/api/usage?source=${Uri.encodeQueryComponent(source)}',
      timeout: const Duration(seconds: 45),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid usage response.');
    }
    return UsageReport.fromJson(decoded.cast<String, Object?>());
  }

  Future<List<QuotaSchedule>> quotaSchedules() async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/quota-schedules',
      timeout: const Duration(seconds: 20),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid quota schedules response.');
    }
    final List<Object?> raw = decoded['schedules'] is List
        ? (decoded['schedules'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map((Map item) => QuotaSchedule.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
  }

  Future<QuotaSchedule> createQuotaSchedule({
    required String sourceKey,
    required String agentKey,
    required String sessionId,
    required String prompt,
    String? targetResetsAt,
    bool replaceExisting = false,
  }) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/quota-schedules',
      body: <String, Object?>{
        'sourceKey': sourceKey,
        'agent': agentKey,
        'sessionId': sessionId,
        'prompt': prompt,
        if (replaceExisting) 'replaceExisting': true,
        if (targetResetsAt != null) 'targetResetsAt': targetResetsAt,
      },
      timeout: const Duration(seconds: 20),
    );
    if (decoded is! Map || decoded['schedule'] is! Map) {
      throw BackendException('Invalid quota schedule response.');
    }
    return QuotaSchedule.fromJson(
      (decoded['schedule'] as Map).cast<String, Object?>(),
    );
  }

  Future<void> cancelQuotaSchedule(String id) async {
    await _requestJson(
      'POST',
      '/api/quota-schedules/cancel',
      body: <String, Object?>{'id': id},
      timeout: const Duration(seconds: 20),
    );
  }

  Future<AgentSessionList> fetchSessions(String agentKey) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/sessions?agent=${Uri.encodeQueryComponent(agentKey)}',
    );
    if (decoded is! Map) {
      throw BackendException('Invalid sessions response.');
    }
    return AgentSessionList.fromJson(decoded.cast<String, Object?>());
  }

  /// Creates a session that starts from a copy of [copySettingsFrom]'s
  /// model/effort/permission/fast settings (Main's when null).
  Future<AgentSessionList> createSession(
    String agentKey,
    String name, {
    String? copySettingsFrom,
  }) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/sessions',
      body: <String, Object?>{
        'agent': agentKey,
        'name': name,
        if (copySettingsFrom != null) 'copySettingsFrom': copySettingsFrom,
      },
    );
    if (decoded is! Map) {
      throw BackendException('Invalid session creation response.');
    }
    return AgentSessionList.fromJson(decoded.cast<String, Object?>());
  }

  Future<AgentSessionList> selectSession(
    String agentKey,
    String sessionId,
  ) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/sessions/active',
      body: <String, Object?>{'agent': agentKey, 'sessionId': sessionId},
    );
    if (decoded is! Map) {
      throw BackendException('Invalid session selection response.');
    }
    return AgentSessionList.fromJson(decoded.cast<String, Object?>());
  }

  Future<AgentSessionList> renameSession(
    String agentKey,
    String sessionId,
    String name,
  ) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/sessions/rename',
      body: <String, Object?>{
        'agent': agentKey,
        'sessionId': sessionId,
        'name': name,
      },
    );
    if (decoded is! Map) {
      throw BackendException('Invalid session rename response.');
    }
    return AgentSessionList.fromJson(decoded.cast<String, Object?>());
  }

  Future<AgentSessionList> deleteSession(
    String agentKey,
    String sessionId,
  ) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/sessions/delete',
      body: <String, Object?>{'agent': agentKey, 'sessionId': sessionId},
    );
    if (decoded is! Map) {
      throw BackendException('Invalid session delete response.');
    }
    return AgentSessionList.fromJson(decoded.cast<String, Object?>());
  }

  /// Fetches the stored conversation for one agent session so the app can show
  /// the previous chat on reopen without persisting anything locally.
  Future<ChatHistory> fetchHistory(
    String agentKey, {
    required String sessionId,
  }) async {
    final String query = 'agent=${Uri.encodeQueryComponent(agentKey)}'
        '&sessionId=${Uri.encodeQueryComponent(sessionId)}';
    final MachineCredential credential = await _requireCredential();
    final Uri uri = _uri(credential, '/api/history?$query');
    late final http.Response response;
    try {
      response = await _httpClient
          .get(uri, headers: await _headers(credential))
          .timeout(const Duration(seconds: 20));
    } on BackendException {
      rethrow;
    } on TimeoutException {
      throw BackendException(
        'Timed out connecting to ${uri.host}.',
        code: 'NETWORK_TIMEOUT',
      );
    } on http.ClientException catch (err) {
      throw _networkExceptionFor(err, uri);
    } catch (err) {
      throw _networkExceptionFor(err, uri);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFor(response.statusCode, response.body);
    }
    if (!kIsWeb && response.body.length > 256 * 1024) {
      return compute(_decodeHistory, response.body);
    }
    return _decodeHistory(response.body);
  }

  // --- Group chat (multi-agent) ---------------------------------------------

  List<ChatGroup> _groupsFrom(Object? decoded) {
    if (decoded is! Map) throw BackendException('Invalid groups response.');
    final List<Object?> raw = decoded['groups'] is List
        ? (decoded['groups'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map((Map item) => ChatGroup.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
  }

  Future<List<ChatGroup>> fetchGroups() async {
    return _groupsFrom(await _requestJson('GET', '/api/groups'));
  }

  Future<List<ChatGroup>> createGroup(
    String name,
    List<String> members, {
    String workdir = '',
    Map<String, Map<String, String>> configs =
        const <String, Map<String, String>>{},
  }) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/groups',
      body: <String, Object?>{
        'name': name,
        'members': members,
        if (workdir.isNotEmpty) 'workdir': workdir,
        if (configs.isNotEmpty) 'configs': configs,
      },
    );
    return _groupsFrom(decoded);
  }

  Future<List<ChatGroup>> setGroupMembers(
    String groupId,
    List<String> members, {
    Map<String, Map<String, String>> configs =
        const <String, Map<String, String>>{},
  }) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/groups/members',
      body: <String, Object?>{
        'groupId': groupId,
        'members': members,
        if (configs.isNotEmpty) 'configs': configs,
      },
    );
    return _groupsFrom(decoded);
  }

  Future<List<ChatGroup>> deleteGroup(String groupId) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/groups/delete',
      body: <String, Object?>{'groupId': groupId},
    );
    return _groupsFrom(decoded);
  }

  Future<GroupHistory> fetchGroupHistory(String groupId) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/group/history?groupId=${Uri.encodeQueryComponent(groupId)}',
    );
    if (decoded is! Map) throw BackendException('Invalid group history.');
    final List<Object?> raw = decoded['messages'] is List
        ? (decoded['messages'] as List).cast<Object?>()
        : const <Object?>[];
    return GroupHistory(
      group: ChatGroup.fromJson(
        (decoded['group'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{},
      ),
      messages: raw
          .whereType<Map>()
          .map((Map item) => ChatMessage.fromJson(item.cast<String, Object?>()))
          .toList(growable: false),
      runningRequestId: decoded['runningRequestId'] as String?,
    );
  }

  /// Post a human message to a group. Sent as plain JSON (not SSE): the per-agent
  /// turn deltas are mirrored to every device on the shared `/api/events` stream,
  /// tagged with `groupId`, so the UI renders from there. Awaiting this resolves
  /// when the whole round (every summoned member) finishes.
  Future<void> sendGroupMessage({
    required String groupId,
    required String prompt,
    required String requestId,
  }) async {
    await _requestJson(
      'POST',
      '/api/group/chat',
      body: <String, Object?>{
        'groupId': groupId,
        'prompt': prompt,
        'requestId': requestId,
      },
      timeout: const Duration(minutes: 65),
    );
  }

  Future<void> cancelGroupMessage(String requestId) async {
    await _requestJson(
      'POST',
      '/api/group/chat/cancel',
      body: <String, Object?>{'requestId': requestId},
    );
  }

  Future<void> clearGroup(String groupId) async {
    await _requestJson(
      'POST',
      '/api/group/clear',
      body: <String, Object?>{'groupId': groupId},
    );
  }

  Future<List<ChatHistorySearchResult>> searchHistory(
    String query, {
    String? agentKey,
  }) async {
    final String trimmed = query.trim();
    final String path =
        '/api/history/search?q=${Uri.encodeQueryComponent(trimmed)}'
        '${agentKey == null || agentKey.isEmpty ? '' : '&agent=${Uri.encodeQueryComponent(agentKey)}'}';
    final Object? decoded = await _requestJson('GET', path);
    if (decoded is! Map) {
      throw BackendException('Invalid search response.');
    }
    final List<Object?> raw = decoded['matches'] is List
        ? (decoded['matches'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map(
          (Map item) =>
              ChatHistorySearchResult.fromJson(item.cast<String, Object?>()),
        )
        .toList(growable: false);
  }

  Future<ConversationExport> exportHistory(
    String agentKey, {
    required String sessionId,
  }) async {
    final String query = 'agent=${Uri.encodeQueryComponent(agentKey)}'
        '&sessionId=${Uri.encodeQueryComponent(sessionId)}';
    final Object? decoded = await _requestJson(
      'GET',
      '/api/history/export?$query',
    );
    if (decoded is! Map) {
      throw BackendException('Invalid history export response.');
    }
    return ConversationExport.fromJson(decoded.cast<String, Object?>());
  }

  /// Best-effort login state per agent so the app can warn before sending a
  /// message. Maps agentKey -> loggedIn, where the value is true/false when the
  /// backend can read the CLI's credentials, or null when it cannot tell.
  Future<Map<String, bool?>> fetchAuthStatus({
    bool verifyCredentials = false,
  }) async {
    final String path = verifyCredentials
        ? '/api/auth/status?verifyCredentials=true'
        : '/api/auth/status';
    final Object? decoded = await _requestJson('GET', path);
    final Map<String, bool?> result = <String, bool?>{};
    if (decoded is Map && decoded['agents'] is List) {
      for (final Object? item in (decoded['agents'] as List)) {
        if (item is! Map) continue;
        final String key = item['key'] as String? ?? '';
        if (key.isEmpty) continue;
        final Object? loggedIn = item['loggedIn'];
        result[key] = loggedIn is bool ? loggedIn : null;
      }
    }
    return result;
  }

  /// The agents the backend host knows about, including install/auth status.
  Future<List<CliAgent>> fetchAgents({bool verifyCredentials = false}) async {
    final String path = verifyCredentials
        ? '/api/agents?verifyCredentials=true'
        : '/api/agents';
    final Object? decoded = await _requestJson('GET', path);
    if (decoded is! Map) {
      throw BackendException('Invalid agents response.');
    }
    final List<Object?> raw = decoded['agents'] is List
        ? (decoded['agents'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map((Map item) => CliAgent.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
  }

  /// Catalog of selectable model/effort/permission/fast options for an agent.
  Future<AgentOptionsCatalog> fetchAgentOptions(String agentKey) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/agent-options?agent=${Uri.encodeQueryComponent(agentKey)}',
    );
    if (decoded is! Map) {
      throw BackendException('Invalid agent options response.');
    }
    return AgentOptionsCatalog.fromJson(decoded.cast<String, Object?>());
  }

  /// Current model/effort/permission/fast selection for one session (Main's
  /// when [sessionId] is null).
  Future<AgentSettings> fetchAgentSettings(
    String agentKey, {
    String? sessionId,
  }) async {
    final String session = sessionId == null
        ? ''
        : '&sessionId=${Uri.encodeQueryComponent(sessionId)}';
    final Object? decoded = await _requestJson(
      'GET',
      '/api/agent-settings?agent=${Uri.encodeQueryComponent(agentKey)}$session',
    );
    if (decoded is! Map || decoded['settings'] is! Map) {
      throw BackendException('Invalid agent settings response.');
    }
    return AgentSettings.fromJson(
      (decoded['settings'] as Map).cast<String, Object?>(),
    );
  }

  /// Persist one supported selection group for a session (Main's when
  /// [sessionId] is null).
  Future<AgentSettings> updateAgentSetting(
    String agentKey,
    String group,
    String optionId, {
    String? sessionId,
  }) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/agent-settings',
      body: <String, Object?>{
        'agent': agentKey,
        group: optionId,
        if (sessionId != null) 'sessionId': sessionId,
      },
    );
    if (decoded is! Map || decoded['settings'] is! Map) {
      throw BackendException('Invalid agent settings response.');
    }
    return AgentSettings.fromJson(
      (decoded['settings'] as Map).cast<String, Object?>(),
    );
  }

  /// Installed CLI version string for the agent (for the model page label).
  Future<String> fetchAgentVersion(String agentKey) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/agent-version?agent=${Uri.encodeQueryComponent(agentKey)}',
    );
    if (decoded is Map && decoded['version'] is String) {
      return (decoded['version'] as String).trim();
    }
    return '';
  }

  /// Update the agent's CLI binary so newly shipped models become selectable.
  /// Slow (network install), so it uses a long timeout.
  Future<AgentUpdateResult> updateAgentCli(String agentKey) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/agent-update',
      body: <String, Object?>{'agent': agentKey},
      timeout: const Duration(seconds: 200),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid agent update response.');
    }
    return AgentUpdateResult.fromJson(decoded.cast<String, Object?>());
  }

  /// Clears the backend-side session for one agent so the next message starts
  /// a new machine-side conversation after local history is cleared.
  Future<void> clearSession(String agentKey, String sessionId) async {
    await _requestJson(
      'POST',
      '/api/session/clear',
      body: <String, Object?>{'agent': agentKey, 'sessionId': sessionId},
    );
  }

  Future<WorkdirInfo> workdir() async {
    final Object? decoded = await _requestJson('GET', '/api/workdir');
    if (decoded is! Map) {
      throw BackendException('Invalid work directory response.');
    }
    return WorkdirInfo.fromJson(decoded.cast<String, Object?>());
  }

  /// Work directories with conversation history on this machine, most recent
  /// first.
  Future<List<String>> recentWorkdirs() async {
    final Object? decoded = await _requestJson('GET', '/api/workdirs/recent');
    final Object? workdirs = decoded is Map ? decoded['workdirs'] : null;
    return workdirs is List
        ? workdirs.whereType<String>().toList(growable: false)
        : const <String>[];
  }

  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) async {
    final MachineCredential credential = await _requireCredential();
    final Object? decoded = await _requestJsonWithCredential(
      credential,
      'POST',
      '/api/workdir',
      body: <String, Object?>{'path': path, 'create': create},
    );
    if (decoded is! Map) {
      throw BackendException('Invalid work directory update response.');
    }
    final WorkdirInfo info = WorkdirInfo.fromJson(
      decoded.cast<String, Object?>(),
    );
    // The backend only validates the path; this device owns its current workdir,
    // so persist the canonical path locally and send it on later requests.
    if (info.dir.isNotEmpty) {
      await _transport.writeWorkdir(credential, info.dir);
    }
    return info;
  }

  Future<FsListing> browseWorkdir(
    String path, {
    bool showHidden = false,
  }) async {
    final String queryPath = Uri.encodeQueryComponent(path);
    final Object? decoded = await _requestJson(
      'GET',
      '/api/workdir/browse?path=$queryPath&showHidden=$showHidden',
    );
    if (decoded is! Map) {
      throw BackendException('Invalid work directory browser response.');
    }
    return FsListing.fromJson(decoded.cast<String, Object?>());
  }

  /// Opens a streaming download. [FsDownloadStream.bytes] is the live response
  /// stream; the caller writes it straight to disk (native) or a blob (web) so a
  /// large file is never buffered whole in memory. Throws before any bytes (e.g.
  /// FS_DOWNLOAD_TOO_LARGE) when the server rejects the request up front.
  Future<FsDownloadStream> openFileDownload(String path) async {
    final MachineCredential credential = await _requireCredential();
    final Uri uri = _uri(
      credential,
      '/api/fs/download?path=${Uri.encodeQueryComponent(path)}',
    );
    final http.Request request = http.Request('GET', uri);
    request.headers.addAll(
      await _headers(credential, accept: 'application/octet-stream'),
    );
    final http.StreamedResponse response =
        await _httpClient.send(request).timeout(const Duration(minutes: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String text = await response.stream.bytesToString();
      throw _exceptionFor(response.statusCode, text);
    }
    final int? total =
        (response.contentLength != null && response.contentLength! > 0)
            ? response.contentLength
            : null;
    return FsDownloadStream(
      fileName: _downloadFileName(response.headers, path),
      total: total,
      bytes: response.stream.timeout(const Duration(minutes: 15)),
    );
  }

  Future<FsEntry> uploadFile({
    required String path,
    required String name,
    required Uint8List bytes,
    bool createDirectory = false,
  }) async {
    final MachineCredential credential = await _requireCredential();
    final Uri uri = _uri(
      credential,
      '/api/fs/upload?path=${Uri.encodeQueryComponent(path)}'
      '&name=${Uri.encodeQueryComponent(name)}'
      '${createDirectory ? '&mkdir=1' : ''}',
    );
    final http.Response response = await _httpClient
        .post(
          uri,
          headers: await _headers(
            credential,
            contentType: 'application/octet-stream',
          ),
          body: bytes,
        )
        .timeout(const Duration(minutes: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFor(response.statusCode, response.body);
    }
    return _uploadedEntryFromBody(response.body);
  }

  Future<FsEntry> uploadFileStream({
    required String path,
    required String name,
    required Stream<List<int>> bytes,
    required int length,
    bool createDirectory = false,
  }) async {
    final MachineCredential credential = await _requireCredential();
    final Uri uri = _uri(
      credential,
      '/api/fs/upload?path=${Uri.encodeQueryComponent(path)}'
      '&name=${Uri.encodeQueryComponent(name)}'
      '${createDirectory ? '&mkdir=1' : ''}',
    );
    final http.StreamedRequest request = http.StreamedRequest('POST', uri);
    request.headers.addAll(
      await _headers(
        credential,
        contentType: 'application/octet-stream',
      ),
    );
    request.contentLength = length;
    final Future<http.StreamedResponse> responseFuture =
        _httpClient.send(request).timeout(const Duration(minutes: 10));
    await request.sink.addStream(bytes);
    await request.sink.close();
    final http.StreamedResponse response = await responseFuture;
    final String body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFor(response.statusCode, body);
    }
    return _uploadedEntryFromBody(body);
  }

  FsEntry _uploadedEntryFromBody(String body) {
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map || decoded['entry'] is! Map) {
      throw BackendException('Invalid file upload response.');
    }
    return FsEntry.fromJson((decoded['entry'] as Map).cast<String, Object?>());
  }

  Stream<BackendEvent> streamEvents() async* {
    final MachineCredential credential = await _requireCredential();
    final http.Request request = http.Request(
      'GET',
      _uri(credential, '/api/events'),
    );
    request.headers.addAll(
      await _headers(credential, accept: 'text/event-stream'),
    );

    final http.StreamedResponse response = await _httpClient.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String text = await response.stream.bytesToString();
      throw _exceptionFor(response.statusCode, text);
    }

    yield* decodeSse(response.stream.timeout(const Duration(seconds: 90)));
  }

  ChatReply _chatReplyFromStreamDone(
    Map<String, Object?> json,
    String requestId,
    String agentKey,
  ) {
    final Map<String, Object?> agent =
        (json['agent'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final Map<String, Object?> message =
        (json['message'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    return ChatReply(
      requestId: json['requestId'] as String? ?? requestId,
      agentKey: agent['key'] as String? ?? agentKey,
      agentLabel: agent['label'] as String? ?? agentKey,
      content: message['content'] as String? ?? '',
      segments: _segmentsFromMessage(message),
      context: (message['context'] as Map?)?.cast<String, Object?>(),
    );
  }

  Future<Object?> _requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration timeout = const Duration(seconds: 20),
  }) =>
      _transport.requestJson(method, path, body: body, timeout: timeout);

  Future<Object?> _requestJsonWithCredential(
    MachineCredential credential,
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration timeout = const Duration(seconds: 20),
  }) =>
      _transport.requestJsonWithCredential(
        credential,
        method,
        path,
        body: body,
        timeout: timeout,
      );

  Future<MachineCredential> _requireCredential() =>
      _transport.requireCredential();

  Uri _uri(MachineCredential credential, String path) =>
      _transport.uri(credential, path);

  Future<Map<String, String>> _headers(
    MachineCredential credential, {
    String accept = 'application/json',
    String contentType = 'application/json',
  }) =>
      _transport.headers(
        credential,
        accept: accept,
        contentType: contentType,
      );

  String _downloadFileName(Map<String, String> headers, String path) {
    final String disposition = headers['content-disposition'] ?? '';
    final RegExpMatch? encoded = RegExp(
      r"filename\*=UTF-8''([^;]+)",
    ).firstMatch(disposition);
    if (encoded != null) {
      return Uri.decodeComponent(encoded.group(1)!);
    }
    final RegExpMatch? plain = RegExp(
      r'filename="?([^";]+)"?',
    ).firstMatch(disposition);
    if (plain != null) return plain.group(1)!;
    final List<String> parts =
        path.split('/').where((String p) => p.isNotEmpty).toList();
    return parts.isEmpty ? 'workdir.zip' : parts.last;
  }

  BackendException _exceptionFor(int status, String body) =>
      _transport.exceptionFor(status, body);

  BackendException _networkExceptionFor(Object err, Uri uri) =>
      _transport.networkExceptionFor(err, uri);
}
