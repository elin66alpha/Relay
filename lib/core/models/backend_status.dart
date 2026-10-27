import '../i18n/app_strings.dart';
import '../util/format_bytes.dart';

class BackendStatus {
  const BackendStatus({
    required this.workdir,
    required this.systemUptime,
    required this.processUptime,
    required this.publicBaseUrl,
  });

  factory BackendStatus.fromJson(Map<String, Object?> json) {
    return BackendStatus(
      workdir: json['workdir'] as String? ?? '',
      systemUptime: json['systemUptime'] as String? ?? '',
      processUptime: json['processUptime'] as String? ?? '',
      publicBaseUrl: json['publicBaseUrl'] as String? ?? '',
    );
  }

  final String workdir;
  final String systemUptime;
  final String processUptime;
  final String publicBaseUrl;

  String toDisplayText(AppStrings strings) {
    final List<String> lines = <String>[
      strings.workDirectoryLine(workdir),
      strings.systemUptimeLine(systemUptime),
      strings.processUptimeLine(processUptime),
      if (publicBaseUrl.isNotEmpty) strings.publicBaseUrlLine(publicBaseUrl),
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
    final Map<String, Object?> workdir = _map('workdir');
    final Map<String, Object?> currentWorkdir =
        (workdir['current'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final List<Object?> agents =
        json['agents'] is List ? (json['agents'] as List).cast<Object?>() : [];
    final List<Object?> storage = json['storage'] is List
        ? (json['storage'] as List).cast<Object?>()
        : [];

    final List<String> lines = <String>[
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

class TemperatureReading {
  const TemperatureReading({
    required this.key,
    required this.label,
    required this.celsius,
  });

  /// mainboard, ssd, cpu or gpu.
  final String key;
  final String label;
  final double celsius;
}

class StorageDisk {
  const StorageDisk({
    required this.mount,
    required this.usedBytes,
    required this.totalBytes,
  });

  final String mount;
  final int usedBytes;
  final int totalBytes;
}

class MachineInfo {
  const MachineInfo({
    required this.cpuModel,
    required this.cpuThreads,
    required this.memoryBytes,
    required this.gpus,
    required this.disks,
    required this.temperatures,
  });

  factory MachineInfo.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> cpu =
        (json['cpu'] as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    return MachineInfo(
      cpuModel: cpu['model']?.toString() ?? '',
      cpuThreads: (cpu['cores'] as num?)?.toInt() ?? 0,
      memoryBytes: (json['memoryBytes'] as num?)?.toInt() ?? 0,
      gpus: <String>[
        for (final Object? gpu in json['gpus'] as List? ?? const <Object?>[])
          if (gpu is String && gpu.isNotEmpty) gpu,
      ],
      disks: <StorageDisk>[
        for (final Object? item in json['disks'] as List? ?? const <Object?>[])
          if (item is Map)
            StorageDisk(
              mount: item['mount']?.toString() ?? '',
              usedBytes: (item['usedBytes'] as num?)?.toInt() ?? 0,
              totalBytes: (item['totalBytes'] as num?)?.toInt() ?? 0,
            ),
      ],
      temperatures: <TemperatureReading>[
        for (final Object? item
            in json['temperatures'] as List? ?? const <Object?>[])
          if (item is Map && item['celsius'] is num)
            TemperatureReading(
              key: item['key']?.toString() ?? '',
              label: item['label']?.toString() ?? '',
              celsius: (item['celsius'] as num).toDouble(),
            ),
      ],
    );
  }

  final String cpuModel;
  final int cpuThreads;
  final int memoryBytes;
  final List<String> gpus;
  final List<StorageDisk> disks;
  final List<TemperatureReading> temperatures;
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
