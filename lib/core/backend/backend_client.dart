import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/machine_credential.dart';
import '../storage/device_id_store.dart';
import '../storage/machine_credentials_store.dart';

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

  String toDisplayText() {
    final int timeoutMinutes = (agentTimeoutMs / 60000).round();
    final List<String> lines = <String>[
      '后端在线',
      '工作目录：$workdir',
      '系统运行：$systemUptime',
      '进程运行：$processUptime',
      if (publicBaseUrl.isNotEmpty) '公网地址：$publicBaseUrl',
      if (timeoutMinutes > 0) '任务超时：$timeoutMinutes 分钟',
      '额度监听：${quotaWatch ? '开启' : '关闭'}',
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

class WorkdirResetResult {
  const WorkdirResetResult({
    required this.dir,
    required this.count,
  });

  final String dir;
  final int count;
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
    http.Client? httpClient,
  })  : _credentialsStore = credentialsStore ?? MachineCredentialsStore(),
        _deviceIdStore = deviceIdStore ?? DeviceIdStore(),
        _httpClient = httpClient ?? http.Client();

  final MachineCredentialsStore _credentialsStore;
  final DeviceIdStore _deviceIdStore;
  final http.Client _httpClient;

  Future<void> close() async {
    _httpClient.close();
  }

  Future<bool> health() async {
    final Object? decoded = await _requestJson('GET', '/api/health');
    return decoded is Map && decoded['ok'] == true;
  }

  Future<bool> healthFor(MachineCredential credential) async {
    final Object? decoded = await _requestJsonWithCredential(
      credential,
      'GET',
      '/api/health',
    );
    return decoded is Map && decoded['ok'] == true;
  }

  Future<BackendStatus> status() async {
    final Object? decoded = await _requestJson('GET', '/api/status');
    if (decoded is! Map) {
      throw BackendException('后端状态响应格式不正确。');
    }
    return BackendStatus.fromJson(decoded.cast<String, Object?>());
  }

  Future<ChatReply> sendMessage({
    required String agentKey,
    required String prompt,
    required String requestId,
  }) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/chat',
      body: <String, Object?>{
        'agent': agentKey,
        'prompt': prompt,
        'requestId': requestId,
      },
      timeout: const Duration(minutes: 65),
    );
    if (decoded is! Map) {
      throw BackendException('后端聊天响应格式不正确。');
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

  Future<void> cancelMessage(String requestId) async {
    await _requestJson(
      'POST',
      '/api/chat/cancel',
      body: <String, Object?>{'requestId': requestId},
      timeout: const Duration(seconds: 10),
    );
  }

  Future<String> usage(String agentKey) async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/usage/$agentKey',
      timeout: const Duration(seconds: 45),
    );
    if (decoded is! Map) {
      throw BackendException('额度响应格式不正确。');
    }
    return decoded['text'] as String? ?? '';
  }

  Future<UsageReport> usageReport() async {
    final Object? decoded = await _requestJson(
      'GET',
      '/api/usage',
      timeout: const Duration(seconds: 45),
    );
    if (decoded is! Map) {
      throw BackendException('额度响应格式不正确。');
    }
    return UsageReport.fromJson(decoded.cast<String, Object?>());
  }

  /// 清掉后端某个 agent 的持久会话，让下一条消息开新会话。
  /// 与本地“清空对话”配套：否则后端仍会 resume 已删除的上下文。
  Future<void> clearSession(String agentKey) async {
    await _requestJson(
      'POST',
      '/api/session/clear',
      body: <String, Object?>{'agent': agentKey},
    );
  }

  Future<WorkdirResetResult> resetWorkdir() async {
    final Object? decoded = await _requestJson('POST', '/api/workdir/reset');
    if (decoded is! Map) {
      throw BackendException('重置工作目录响应格式不正确。');
    }
    return WorkdirResetResult(
      dir: decoded['dir'] as String? ?? '',
      count: decoded['count'] as int? ?? 0,
    );
  }

  Future<WorkdirInfo> workdir() async {
    final Object? decoded = await _requestJson('GET', '/api/workdir');
    if (decoded is! Map) {
      throw BackendException('工作路径响应格式不正确。');
    }
    return WorkdirInfo.fromJson(decoded.cast<String, Object?>());
  }

  Future<WorkdirInfo> checkWorkdir(String path) async {
    final Object? decoded = await _requestJson(
      'POST',
      '/api/workdir/check',
      body: <String, Object?>{'path': path},
    );
    if (decoded is! Map) {
      throw BackendException('工作路径检查响应格式不正确。');
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
      throw BackendException('工作路径设置响应格式不正确。');
    }
    return WorkdirInfo.fromJson(decoded.cast<String, Object?>());
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

    String eventType = 'message';
    final StringBuffer data = StringBuffer();
    await for (final String line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
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
    if (method == 'GET') {
      response = await _httpClient.get(uri, headers: headers).timeout(timeout);
    } else if (method == 'POST') {
      response = await _httpClient
          .post(uri, headers: headers, body: jsonEncode(body ?? const {}))
          .timeout(timeout);
    } else {
      throw BackendException('Unsupported method: $method');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionFor(response.statusCode, response.body);
    }
    if (response.body.trim().isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw BackendException('后端返回了非 JSON 内容。');
    }
  }

  Future<MachineCredential> _requireCredential() async {
    final MachineCredential? credential = await _credentialsStore.readActive();
    if (credential == null) {
      throw BackendException('请先导入这台机器提供的凭证文件。');
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
  }) async {
    final String deviceId = await _deviceIdStore.readOrCreate();
    return <String, String>{
      'Accept': accept,
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${credential.token.trim()}',
      'X-Device-Id': deviceId,
    };
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
