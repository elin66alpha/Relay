import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../i18n/app_strings.dart';
import '../models/agent_session.dart';
import '../models/chat_message.dart';
import '../models/machine_credential.dart';
import '../storage/device_id_store.dart';
import '../storage/machine_credentials_store.dart';
import '../storage/workdir_store.dart';

class BackendException implements Exception {
  BackendException(this.message, {this.status, this.code});

  final String message;
  final int? status;
  final String? code;

  @override
  String toString() => 'BackendException(${status ?? '-'}): $message';
}

class BackendStatus {
  const BackendStatus({
    required this.workdir,
    required this.systemUptime,
    required this.processUptime,
    required this.agentTimeoutMs,
    required this.quotaWatch,
    required this.publicBaseUrl,
  });

  factory BackendStatus.fromJson(Map<String, Object?> json) {
    return BackendStatus(
      workdir: json['workdir'] as String? ?? '',
      systemUptime: json['systemUptime'] as String? ?? '',
      processUptime: json['processUptime'] as String? ?? '',
      agentTimeoutMs: json['agentTimeoutMs'] as int? ?? 0,
      quotaWatch: json['quotaWatch'] as bool? ?? false,
      publicBaseUrl: json['publicBaseUrl'] as String? ?? '',
    );
  }

  final String workdir;
  final String systemUptime;
  final String processUptime;
  final int agentTimeoutMs;
  final bool quotaWatch;
  final String publicBaseUrl;

  String toDisplayText(AppStrings strings) {
    final int timeoutMinutes = (agentTimeoutMs / 60000).round();
    final List<String> lines = <String>[
      strings.backendOnline,
      strings.workDirectoryLine(workdir),
      strings.systemUptimeLine(systemUptime),
      strings.processUptimeLine(processUptime),
      if (publicBaseUrl.isNotEmpty) strings.publicBaseUrlLine(publicBaseUrl),
      if (timeoutMinutes > 0) strings.taskTimeoutLine(timeoutMinutes),
      strings.quotaWatchLine(quotaWatch),
    ];
    return lines.join('\n');
  }
}

class ChatReply {
  const ChatReply({
    required this.requestId,
    required this.agentKey,
    required this.agentLabel,
    required this.content,
  });

  final String requestId;
  final String agentKey;
  final String agentLabel;
  final String content;
}

class WorkdirInfo {
  const WorkdirInfo({
    required this.dir,
    this.exists = true,
    this.isDirectory = true,
    this.busy = false,
    this.created = false,
  });

  factory WorkdirInfo.fromJson(Map<String, Object?> json) {
    return WorkdirInfo(
      dir: json['dir'] as String? ?? '',
      exists: json['exists'] as bool? ?? true,
      isDirectory: json['isDirectory'] as bool? ?? true,
      busy: json['busy'] as bool? ?? false,
      created: json['created'] as bool? ?? false,
    );
  }

  final String dir;
  final bool exists;
  final bool isDirectory;
  final bool busy;
  final bool created;
}

class AgentSessionList {
  const AgentSessionList({
    required this.agentKey,
    required this.workdir,
    required this.activeSessionId,
    required this.sessions,
  });

  factory AgentSessionList.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> agent =
        (json['agent'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final List<Object?> rawSessions = json['sessions'] is List
        ? (json['sessions'] as List).cast<Object?>()
        : const <Object?>[];
    final List<AgentSession> sessions = rawSessions
        .whereType<Map>()
        .map((Map item) => AgentSession.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
    final String activeSessionId = json['activeSessionId'] as String? ??
        (sessions.isNotEmpty ? sessions.first.id : AgentSession.defaultId);
    return AgentSessionList(
      agentKey: agent['key'] as String? ?? '',
      workdir: json['workdir'] as String? ?? '',
      activeSessionId: activeSessionId,
      sessions:
          sessions.isEmpty ? <AgentSession>[AgentSession.fallback()] : sessions,
    );
  }

  final String agentKey;
  final String workdir;
  final String activeSessionId;
  final List<AgentSession> sessions;

  AgentSession get activeSession {
    for (final AgentSession session in sessions) {
      if (session.id == activeSessionId) return session;
    }
    return sessions.isNotEmpty ? sessions.first : AgentSession.fallback();
  }
}

class FsEntry {
  const FsEntry({
    required this.name,
    required this.path,
    required this.absolutePath,
    required this.type,
    required this.size,
    required this.modifiedAt,
  });

  factory FsEntry.fromJson(Map<String, Object?> json) {
    return FsEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      absolutePath: json['absolutePath'] as String? ?? '',
      type: json['type'] as String? ?? 'other',
      size: (json['size'] as num?)?.toInt() ?? 0,
      modifiedAt: json['modifiedAt'] as String? ?? '',
    );
  }

  final String name;
  final String path;
  final String absolutePath;
  final String type;
  final int size;
  final String modifiedAt;

  bool get isDirectory => type == 'directory';
  bool get isFile => type == 'file';
}

class FsListing {
  const FsListing({
    required this.root,
    required this.path,
    required this.absolutePath,
    required this.entries,
    this.parentPath,
  });

  factory FsListing.fromJson(Map<String, Object?> json) {
    final List<Object?> rawEntries = json['entries'] is List
        ? (json['entries'] as List).cast<Object?>()
        : const <Object?>[];
    return FsListing(
      root: json['root'] as String? ?? '',
      path: json['path'] as String? ?? '',
      absolutePath: json['absolutePath'] as String? ?? '',
      parentPath: json['parentPath'] as String?,
      entries: rawEntries
          .whereType<Map>()
          .map((Map entry) => FsEntry.fromJson(entry.cast<String, Object?>()))
          .toList(growable: false),
    );
  }

  final String root;
  final String path;
  final String absolutePath;
  final String? parentPath;
  final List<FsEntry> entries;
}

/// An in-progress file download: response metadata plus the live byte stream.
/// The caller consumes [bytes] straight to its destination (a file on native, a
/// blob on web) so a large download is never buffered whole in memory.
class FsDownloadStream {
  const FsDownloadStream({
    required this.fileName,
    required this.total,
    required this.bytes,
  });

  final String fileName;

  /// Total bytes when the server announced a Content-Length, else null.
  final int? total;

  final Stream<List<int>> bytes;
}

class UsageQuota {
  const UsageQuota({
    required this.key,
    required this.label,
    required this.remainingPercent,
    required this.resetsAt,
  });

  factory UsageQuota.fromJson(Map<String, Object?> json) {
    return UsageQuota(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      remainingPercent: (json['remainingPercent'] as num?)?.toDouble(),
      resetsAt: json['resetsAt'] as String?,
    );
  }

  final String key;
  final String label;
  final double? remainingPercent;
  final String? resetsAt;
}

class UsageAgent {
  const UsageAgent({
    required this.key,
    required this.label,
    required this.available,
    required this.quotas,
    this.detail = '',
    this.error,
    this.unavailableReason,
  });

  factory UsageAgent.fromJson(Map<String, Object?> json) {
    final List<Object?> rawQuotas = json['quotas'] is List
        ? (json['quotas'] as List).cast<Object?>()
        : const <Object?>[];
    return UsageAgent(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      available: json['available'] as bool? ?? false,
      detail: json['detail'] as String? ?? '',
      error: json['error'] as String?,
      unavailableReason: json['unavailableReason'] as String?,
      quotas: rawQuotas
          .whereType<Map>()
          .map((Map q) => UsageQuota.fromJson(q.cast<String, Object?>()))
          .toList(growable: false),
    );
  }

  final String key;
  final String label;
  final bool available;
  final String detail;
  final String? error;
  final String? unavailableReason;
  final List<UsageQuota> quotas;
}

class UsageReport {
  const UsageReport({
    required this.createdAt,
    required this.agents,
  });

  factory UsageReport.fromJson(Map<String, Object?> json) {
    final List<Object?> rawAgents = json['agents'] is List
        ? (json['agents'] as List).cast<Object?>()
        : const <Object?>[];
    return UsageReport(
      createdAt: json['createdAt'] as String? ?? '',
      agents: rawAgents
          .whereType<Map>()
          .map(
            (Map agent) => UsageAgent.fromJson(agent.cast<String, Object?>()),
          )
          .toList(growable: false),
    );
  }

  final String createdAt;
  final List<UsageAgent> agents;
}

class BackendEvent {
  const BackendEvent({
    required this.type,
    required this.data,
  });

  final String type;
  final Map<String, Object?> data;
}

class BackendClient {
  BackendClient({
    MachineCredentialsStore? credentialsStore,
    DeviceIdStore? deviceIdStore,
    WorkdirStore? workdirStore,
    http.Client? httpClient,
  })  : _credentialsStore = credentialsStore ?? MachineCredentialsStore(),
        _deviceIdStore = deviceIdStore ?? DeviceIdStore(),
        _workdirStore = workdirStore ?? WorkdirStore(),
        _httpClient = httpClient ?? http.Client();

  final MachineCredentialsStore _credentialsStore;
  final DeviceIdStore _deviceIdStore;
  final WorkdirStore _workdirStore;
  final http.Client _httpClient;

  /// This device's current work directory, or null when it has not chosen one
  /// (the backend then uses its default).
  Future<String?> currentWorkdir() => _workdirStore.read();

  Future<void> close() async {
    _httpClient.close();
  }

  Future<bool> health({
    Duration timeout = const Duration(seconds: 20),
  }) async {
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

  Future<ChatReply> sendMessage({
    required String agentKey,
    required String sessionId,
    required String prompt,
    required String requestId,
    void Function(BackendEvent event)? onEvent,
  }) async {
    if (onEvent != null) {
      return _sendMessageStreamed(
        agentKey: agentKey,
        sessionId: sessionId,
        prompt: prompt,
        requestId: requestId,
        onEvent: onEvent,
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
    );
  }

  Future<void> compressConversation({
    required String agentKey,
    required String sessionId,
    required String requestId,
  }) async {
    await _requestJson(
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
  }

  Future<ChatReply> _sendMessageStreamed({
    required String agentKey,
    required String sessionId,
    required String prompt,
    required String requestId,
    required void Function(BackendEvent event) onEvent,
  }) async {
    final MachineCredential credential = await _requireCredential();
    final http.Request request = http.Request(
      'POST',
      _uri(credential, '/api/chat'),
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

    final http.StreamedResponse response =
        await _httpClient.send(request).timeout(const Duration(minutes: 65));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final String text = await response.stream.bytesToString();
      throw _exceptionFor(response.statusCode, text);
    }

    ChatReply? reply;
    BackendException? streamError;
    await for (final BackendEvent event
        in _parseSse(response.stream).timeout(const Duration(minutes: 65))) {
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
    if (streamError != null) throw streamError;
    if (reply == null) {
      throw BackendException('Agent stream ended without a final response.');
    }
    return reply;
  }

  Future<void> cancelMessage(String requestId) async {
    await _requestJson(
      'POST',
      '/api/chat/cancel',
      body: <String, Object?>{'requestId': requestId},
      timeout: const Duration(seconds: 10),
    );
  }

  Future<UsageReport> usageReport() async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/usage',
      timeout: const Duration(seconds: 45),
    );
    if (decoded is! Map) {
      throw BackendException('Invalid usage response.');
    }
    return UsageReport.fromJson(decoded.cast<String, Object?>());
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

  Future<AgentSessionList> createSession(String agentKey, String name) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/sessions',
      body: <String, Object?>{'agent': agentKey, 'name': name},
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
  Future<List<ChatMessage>> fetchHistory(
    String agentKey, {
    required String sessionId,
  }) async {
    final String query = 'agent=${Uri.encodeQueryComponent(agentKey)}'
        '&sessionId=${Uri.encodeQueryComponent(sessionId)}';
    final Object? decoded = await _requestJson('GET', '/api/history?$query');
    if (decoded is! Map) {
      throw BackendException('历史响应格式不正确。');
    }
    final List<Object?> raw = decoded['messages'] is List
        ? (decoded['messages'] as List).cast<Object?>()
        : const <Object?>[];
    return raw
        .whereType<Map>()
        .map((Map item) => ChatMessage.fromJson(item.cast<String, Object?>()))
        .toList(growable: false);
  }

  /// Best-effort login state per agent so the app can warn before sending a
  /// message. Maps agentKey -> loggedIn, where the value is true/false when the
  /// backend can read the CLI's credentials, or null when it cannot tell (agy).
  Future<Map<String, bool?>> fetchAuthStatus() async {
    final Object? decoded = await _requestJson('GET', '/api/auth/status');
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

  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/workdir',
      body: <String, Object?>{'path': path, 'create': create},
    );
    if (decoded is! Map) {
      throw BackendException('Invalid work directory update response.');
    }
    final WorkdirInfo info =
        WorkdirInfo.fromJson(decoded.cast<String, Object?>());
    // The backend only validates the path; this device owns its current workdir,
    // so persist the canonical path locally and send it on later requests.
    if (info.dir.isNotEmpty) {
      await _workdirStore.write(info.dir);
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
  }) async {
    final MachineCredential credential = await _requireCredential();
    final Uri uri = _uri(
      credential,
      '/api/fs/upload?path=${Uri.encodeQueryComponent(path)}'
      '&name=${Uri.encodeQueryComponent(name)}',
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
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['entry'] is! Map) {
      throw BackendException('Invalid file upload response.');
    }
    return FsEntry.fromJson(
      (decoded['entry'] as Map).cast<String, Object?>(),
    );
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

    yield* _parseSse(response.stream);
  }

  Stream<BackendEvent> _parseSse(Stream<List<int>> stream) async* {
    String eventType = 'message';
    final StringBuffer data = StringBuffer();
    await for (final String line
        in stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          yield BackendEvent(type: eventType, data: _decodeEventData(data));
        }
        eventType = 'message';
        data.clear();
        continue;
      }
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.writeln();
        data.write(line.substring(5).trimLeft());
      }
    }
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
    );
  }

  Future<Object?> _requestJson(
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final MachineCredential credential = await _requireCredential();
    return _requestJsonWithCredential(
      credential,
      method,
      path,
      body: body,
      timeout: timeout,
    );
  }

  Future<Object?> _requestJsonWithCredential(
    MachineCredential credential,
    String method,
    String path, {
    Map<String, Object?>? body,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Uri uri = _uri(credential, path);
    final Map<String, String> headers = await _headers(credential);
    late final http.Response response;
    try {
      if (method == 'GET') {
        response =
            await _httpClient.get(uri, headers: headers).timeout(timeout);
      } else if (method == 'POST') {
        response = await _httpClient
            .post(uri, headers: headers, body: jsonEncode(body ?? const {}))
            .timeout(timeout);
      } else {
        throw BackendException('Unsupported method: $method');
      }
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
    if (response.body.trim().isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw BackendException('Backend returned non-JSON content.');
    }
  }

  Future<MachineCredential> _requireCredential() async {
    final MachineCredential? credential = await _credentialsStore.readActive();
    if (credential == null) {
      throw BackendException('Import a machine credential first.');
    }
    return credential;
  }

  Uri _uri(MachineCredential credential, String path) {
    final String base = credential.baseUrl.endsWith('/')
        ? credential.baseUrl
        : '${credential.baseUrl}/';
    final String cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse(base).resolve(cleanPath);
  }

  Future<Map<String, String>> _headers(
    MachineCredential credential, {
    String accept = 'application/json',
    String contentType = 'application/json',
  }) async {
    final String deviceId = await _deviceIdStore.readOrCreate();
    final String? workdir = await _workdirStore.read();
    return <String, String>{
      'Accept': accept,
      'Content-Type': contentType,
      'Authorization': 'Bearer ${credential.token.trim()}',
      'X-Device-Id': deviceId,
      if (workdir != null && workdir.isNotEmpty) 'X-Workdir': workdir,
    };
  }

  String _downloadFileName(Map<String, String> headers, String path) {
    final String disposition = headers['content-disposition'] ?? '';
    final RegExpMatch? encoded =
        RegExp(r"filename\*=UTF-8''([^;]+)").firstMatch(disposition);
    if (encoded != null) {
      return Uri.decodeComponent(encoded.group(1)!);
    }
    final RegExpMatch? plain =
        RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
    if (plain != null) return plain.group(1)!;
    final List<String> parts =
        path.split('/').where((String p) => p.isNotEmpty).toList();
    return parts.isEmpty ? 'workdir.zip' : parts.last;
  }

  BackendException _exceptionFor(int status, String body) {
    String message = body.trim();
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map) {
        if (decoded['error'] != null) {
          message = decoded['error'].toString();
        }
        return BackendException(
          message.isEmpty ? 'HTTP $status' : message,
          status: status,
          code: decoded['code']?.toString(),
        );
      }
    } on FormatException {
      // Keep raw body.
    }
    if (message.isEmpty) message = 'HTTP $status';
    return BackendException(message, status: status);
  }

  BackendException _networkExceptionFor(Object err, Uri uri) {
    final String raw = err.toString();
    final String lower = raw.toLowerCase();
    String code = 'NETWORK_ERROR';
    if (lower.contains('failed host lookup') ||
        lower.contains('no address associated') ||
        lower.contains('name_not_resolved') ||
        lower.contains('nodename nor servname')) {
      code = 'NETWORK_HOST_LOOKUP';
    } else if (lower.contains('connection refused')) {
      code = 'NETWORK_CONNECTION_REFUSED';
    } else if (lower.contains('network is unreachable') ||
        lower.contains('no route to host')) {
      code = 'NETWORK_UNREACHABLE';
    }
    return BackendException(raw, code: code);
  }

  Map<String, Object?> _decodeEventData(StringBuffer data) {
    try {
      final Object? decoded = jsonDecode(data.toString());
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Fall through.
    }
    return <String, Object?>{'text': data.toString()};
  }
}
