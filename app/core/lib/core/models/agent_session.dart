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
