class UsageQuota {
  const UsageQuota({
    required this.key,
    required this.label,
    required this.remainingPercent,
    required this.resetsAt,
    this.expired = false,
  });

  factory UsageQuota.fromJson(Map<String, Object?> json) {
    return UsageQuota(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      remainingPercent: (json['remainingPercent'] as num?)?.toDouble(),
      resetsAt: json['resetsAt'] as String?,
      expired: json['expired'] as bool? ?? false,
    );
  }

  final String key;
  final String label;
  final double? remainingPercent;
  final String? resetsAt;

  /// True when this is a stale cached bucket whose reset window has already
  /// passed, so [remainingPercent] no longer reflects reality and the UI should
  /// show a "window reset, awaiting refresh" hint instead of the old number.
  final bool expired;
}

class UsageAgent {
  const UsageAgent({
    required this.key,
    required this.label,
    required this.available,
    required this.stale,
    required this.quotas,
    this.detail = '',
    this.asOf,
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
      stale: json['stale'] as bool? ?? false,
      detail: json['detail'] as String? ?? '',
      asOf: json['asOf'] as String?,
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
  final bool stale;
  final String detail;
  final String? asOf;
  final String? error;
  final String? unavailableReason;
  final List<UsageQuota> quotas;
}

class UsageReport {
  const UsageReport({
    required this.createdAt,
    required this.agents,
    required this.hasStale,
  });

  factory UsageReport.fromJson(Map<String, Object?> json) {
    final List<Object?> rawAgents = json['agents'] is List
        ? (json['agents'] as List).cast<Object?>()
        : const <Object?>[];
    return UsageReport(
      createdAt: json['createdAt'] as String? ?? '',
      hasStale: json['hasStale'] as bool? ?? false,
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
  final bool hasStale;

  /// This report with [other]'s agents replacing same-key entries in place and
  /// new ones appended, so per-source queries can land one at a time.
  UsageReport merge(UsageReport other) {
    final List<UsageAgent> merged = <String, UsageAgent>{
      for (final UsageAgent agent in agents) agent.key: agent,
      for (final UsageAgent agent in other.agents) agent.key: agent,
    }.values.toList(growable: false);
    return UsageReport(
      createdAt: other.createdAt,
      agents: merged,
      hasStale: merged.any((UsageAgent agent) => agent.stale),
    );
  }
}

class QuotaSchedule {
  const QuotaSchedule({
    required this.id,
    required this.sourceKey,
    required this.agentKey,
    required this.sessionId,
    required this.workdir,
    required this.prompt,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.sessionName = '',
    this.targetResetsAt,
    this.sentAt,
    this.error,
  });

  factory QuotaSchedule.fromJson(Map<String, Object?> json) {
    return QuotaSchedule(
      id: json['id'] as String? ?? '',
      sourceKey: json['sourceKey'] as String? ?? '',
      agentKey: json['agentKey'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      sessionName: json['sessionName'] as String? ?? '',
      workdir: json['workdir'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      targetResetsAt: json['targetResetsAt'] as String?,
      status: json['status'] as String? ?? 'pending',
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
      sentAt: json['sentAt'] as String?,
      error: json['error'] as String?,
    );
  }

  final String id;
  final String sourceKey;
  final String agentKey;
  final String sessionId;
  final String sessionName;
  final String workdir;
  final String prompt;
  final String? targetResetsAt;
  final String status;
  final String createdAt;
  final String updatedAt;
  final String? sentAt;
  final String? error;

  bool get canCancel => status == 'pending';
}
