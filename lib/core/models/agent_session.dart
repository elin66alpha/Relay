class AgentSession {
  const AgentSession({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AgentSession.fromJson(Map<String, Object?> json) {
    final DateTime now = DateTime.now();
    return AgentSession(
      id: json['id'] as String? ?? defaultId,
      name: json['name'] as String? ?? 'Main',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? now,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? now,
    );
  }

  factory AgentSession.fallback() {
    final DateTime now = DateTime.now();
    return AgentSession(
      id: defaultId,
      name: 'Main',
      createdAt: now,
      updatedAt: now,
    );
  }

  static const String defaultId = 'default';

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isDefault => id == defaultId;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }
}
