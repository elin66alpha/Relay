import '../i18n/app_strings.dart';
import '../util/format_bytes.dart';

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

class DeviceToken {
  const DeviceToken({
    required this.id,
    required this.label,
    required this.createdAt,
    required this.revoked,
    required this.current,
    required this.lastDeviceId,
    required this.lastDeviceName,
    this.revokedAt,
    this.lastUsedAt,
  });

  factory DeviceToken.fromJson(Map<String, Object?> json) {
    final String revokedAt = json['revokedAt'] as String? ?? '';
    final String lastUsedAt = json['lastUsedAt'] as String? ?? '';
    return DeviceToken(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      revoked: json['revoked'] as bool? ?? false,
      current: json['current'] as bool? ?? false,
      lastDeviceId: json['lastDeviceId'] as String? ?? '',
      lastDeviceName: json['lastDeviceName'] as String? ?? '',
      revokedAt: revokedAt.isEmpty ? null : revokedAt,
      lastUsedAt: lastUsedAt.isEmpty ? null : lastUsedAt,
    );
  }

  final String id;
  final String label;
  final String createdAt;
  final bool revoked;
  final bool current;
  final String lastDeviceId;
  final String lastDeviceName;
  final String? revokedAt;
  final String? lastUsedAt;

  DeviceToken copyWith({bool? revoked, String? revokedAt}) {
    return DeviceToken(
      id: id,
      label: label,
      createdAt: createdAt,
      revoked: revoked ?? this.revoked,
      current: current,
      lastDeviceId: lastDeviceId,
      lastDeviceName: lastDeviceName,
      revokedAt: revokedAt ?? this.revokedAt,
      lastUsedAt: lastUsedAt,
    );
  }
}

class BackendDiagnostics {
  const BackendDiagnostics(this.json);

  factory BackendDiagnostics.fromJson(Map<String, Object?> json) {
    return BackendDiagnostics(json);
  }

  final Map<String, Object?> json;

  Map<String, Object?> _map(String key) =>
      (json[key] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};

  String _string(Map<String, Object?> map, String key) =>
      map[key]?.toString() ?? '';

  int _int(Map<String, Object?> map, String key) =>
      (map[key] as num?)?.toInt() ?? 0;

  bool _bool(Map<String, Object?> map, String key) =>
      map[key] as bool? ?? false;

  String toDisplayText(AppStrings strings) {
    final Map<String, Object?> server = _map('server');
    final Map<String, Object?> runtime = _map('runtime');
    final Map<String, Object?> auth = _map('auth');
    final Map<String, Object?> workdir = _map('workdir');
    final Map<String, Object?> currentWorkdir =
        (workdir['current'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final Map<String, Object?> defaultWorkdir =
        (workdir['default'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final List<Object?> agents =
        json['agents'] is List ? (json['agents'] as List).cast<Object?>() : [];
    final List<Object?> storage = json['storage'] is List
        ? (json['storage'] as List).cast<Object?>()
        : [];

    final int timeoutMinutes = (_int(server, 'agentTimeoutMs') / 60000).round();
    final List<String> lines = <String>[
      strings.backendOnline,
      strings.diagnosticsGeneratedLine(json['createdAt']?.toString() ?? ''),
      strings.diagnosticsRuntimeLine(
        _string(server, 'platform'),
        _string(server, 'arch'),
        _string(server, 'node'),
      ),
      strings.diagnosticsListenLine(
        _string(server, 'host'),
        _int(server, 'port'),
      ),
      if (_string(server, 'publicBaseUrl').isNotEmpty)
        strings.publicBaseUrlLine(_string(server, 'publicBaseUrl')),
      strings.workDirectoryLine(_string(currentWorkdir, 'dir')),
      strings.diagnosticsWorkdirLine(
        exists: _bool(currentWorkdir, 'exists'),
        writable: _bool(currentWorkdir, 'writable'),
      ),
      strings.diagnosticsDefaultWorkdirLine(_string(defaultWorkdir, 'dir')),
      if (timeoutMinutes > 0) strings.taskTimeoutLine(timeoutMinutes),
      strings.quotaWatchLine(_bool(server, 'quotaWatch')),
      strings.diagnosticsTransferLimitLine(
        formatBytes(_int(server, 'maxUploadBytes')),
        formatBytes(_int(server, 'maxDownloadBytes')),
      ),
      strings.diagnosticsTokenLine(
        configured: _bool(auth, 'configured'),
        active: _int(auth, 'active'),
        total: _int(auth, 'total'),
      ),
      strings.diagnosticsRequestLine(
        active: _int(runtime, 'activeRequests'),
        running: _int(runtime, 'runningScopes'),
        queued: _int(runtime, 'queuedScopes'),
        sse: _int(runtime, 'sseClients'),
      ),
      strings.diagnosticsWebBuildLine(
        ((server['webBuild'] as Map?)?.cast<String, Object?>() ??
                const <String, Object?>{})['indexExists'] ==
            true,
      ),
      '',
      strings.diagnosticsAgentsHeader,
      for (final Object? item in agents)
        _agentLine(strings, (item as Map?)?.cast<String, Object?>()),
      '',
      strings.diagnosticsStorageHeader,
      for (final Object? item in storage)
        _storageLine(strings, (item as Map?)?.cast<String, Object?>()),
    ];
    return lines.where((String line) => line.trim().isNotEmpty).join('\n');
  }

  String _agentLine(AppStrings strings, Map<String, Object?>? item) {
    final Map<String, Object?> agent = item ?? const <String, Object?>{};
    final Map<String, Object?> cli =
        (agent['cli'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    return strings.diagnosticsAgentLine(
      agent['label']?.toString() ?? agent['key']?.toString() ?? '',
      available: cli['available'] == true,
      loggedIn: agent['loggedIn'] as bool?,
      path: cli['path']?.toString() ?? '',
    );
  }

  String _storageLine(AppStrings strings, Map<String, Object?>? item) {
    final Map<String, Object?> file = item ?? const <String, Object?>{};
    return strings.diagnosticsStorageLine(
      file['name']?.toString() ?? '',
      exists: file['exists'] == true,
      writable: file['writable'] == true,
      size: formatBytes((file['sizeBytes'] as num?)?.toInt() ?? 0),
    );
  }
}

class PushConfig {
  const PushConfig({required this.enabled, required this.publicKey});

  factory PushConfig.fromJson(Map<String, Object?> json) {
    return PushConfig(
      enabled: json['enabled'] as bool? ?? false,
      publicKey: json['publicKey'] as String? ?? '',
    );
  }

  final bool enabled;
  final String publicKey;
}
