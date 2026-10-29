class MachineCredential {
  const MachineCredential({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.token,
    required this.createdAt,
  });

  factory MachineCredential.fromJson(Map<String, Object?> json) {
    return MachineCredential(
      id: _cleanString(json['id']),
      name: _cleanString(json['name']),
      baseUrl: _normalizeBaseUrl(_cleanString(json['baseUrl'])),
      token: _cleanString(json['token']),
      createdAt: _cleanString(json['createdAt']),
    );
  }

  final String id;
  final String name;
  final String baseUrl;
  final String token;
  final String createdAt;

  String get displayName => name.isEmpty ? 'Unnamed machine' : name;

  String get hostLabel {
    final Uri? parsed = Uri.tryParse(baseUrl);
    if (parsed == null || parsed.host.isEmpty) return baseUrl;
    return parsed.hasPort ? '${parsed.host}:${parsed.port}' : parsed.host;
  }

  MachineCredential copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? token,
    String? createdAt,
  }) {
    return MachineCredential(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl == null ? this.baseUrl : _normalizeBaseUrl(baseUrl),
      token: token ?? this.token,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'baseUrl': baseUrl,
      'token': token,
      'createdAt': createdAt,
    };
  }

  void validate() {
    if (id.trim().isEmpty) {
      throw const MachineCredentialException(
        'Credential is missing a machine id.',
      );
    }
    if (baseUrl.trim().isEmpty) {
      throw const MachineCredentialException(
        'Credential is missing a public URL.',
      );
    }
    final Uri? parsed = Uri.tryParse(baseUrl);
    if (parsed == null ||
        parsed.host.isEmpty ||
        !(parsed.isScheme('http') || parsed.isScheme('https'))) {
      throw const MachineCredentialException(
        'The credential URL must start with http:// or https://.',
      );
    }
    if (token.trim().isEmpty) {
      throw const MachineCredentialException(
        'Credential is missing an access token.',
      );
    }
  }
}

class MachineCredentialException implements Exception {
  const MachineCredentialException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _cleanString(Object? value) {
  if (value == null) return '';
  return value.toString().trim();
}

String _normalizeBaseUrl(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.endsWith('/')) {
    return trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}
