class AlwaysOnSession {
  const AlwaysOnSession({
    required this.agentKey,
    required this.workdir,
    required this.sessionId,
    required this.name,
  });

  factory AlwaysOnSession.fromJson(Map<String, Object?> json) {
    final String sessionId = json['sessionId'] as String? ?? 'default';
    return AlwaysOnSession(
      agentKey: json['agent'] as String? ?? '',
      workdir: json['workdir'] as String? ?? '',
      sessionId: sessionId,
      name: json['name'] as String? ??
          (sessionId == 'default' ? 'Main' : sessionId),
    );
  }

  final String agentKey;
  final String workdir;
  final String sessionId;
  final String name;
}

class AlwaysOnSessionList {
  const AlwaysOnSessionList({
    required this.max,
    required this.sessions,
  });

  factory AlwaysOnSessionList.fromJson(Map<String, Object?> json) {
    final int max = (json['max'] as num?)?.toInt() ?? 3;
    final List<Object?> raw = json['sessions'] is List
        ? (json['sessions'] as List).cast<Object?>()
        : const <Object?>[];
    final List<AlwaysOnSession> sessions = raw
        .whereType<Map>()
        .map(
          (Map item) => AlwaysOnSession.fromJson(item.cast<String, Object?>()),
        )
        .toList(growable: false);
    return AlwaysOnSessionList(max: max, sessions: sessions);
  }

  final int max;
  final List<AlwaysOnSession> sessions;
}
