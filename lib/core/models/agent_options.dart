// Client models for the per-agent Model / Effort / Permission controls exposed
// in the chat composer's "+" drawer. Mirrors the backend `/api/agent-options`
// catalog and `/api/agent-settings` selection (server/lib/agent-options.js).

/// One selectable value within a control group (a model, an effort level, or a
/// permission tier).
class AgentOption {
  const AgentOption({required this.id, required this.label, this.description});

  final String id;
  final String label;
  final String? description;

  factory AgentOption.fromJson(Map<String, Object?> json) {
    return AgentOption(
      id: (json['id'] as String?)?.trim() ?? '',
      label: (json['label'] as String?)?.trim() ?? '',
      description: (json['description'] as String?)?.trim().isNotEmpty == true
          ? (json['description'] as String).trim()
          : null,
    );
  }
}

/// The three control groups, keyed by group name (`model` / `effort` /
/// `permission`). Each group is the ordered list of choices for the agent.
class AgentOptionsCatalog {
  const AgentOptionsCatalog({
    required this.agent,
    required this.supports,
    required this.model,
    required this.effort,
    required this.permission,
    required this.defaults,
  });

  final String agent;

  /// Whether the agent supports each group at all.
  final Map<String, bool> supports;

  final List<AgentOption> model;
  final List<AgentOption> effort;
  final List<AgentOption> permission;

  /// Default selection ids per group.
  final Map<String, String> defaults;

  bool supportsGroup(String group) => supports[group] == true;

  List<AgentOption> optionsFor(String group) {
    switch (group) {
      case 'model':
        return model;
      case 'effort':
        return effort;
      case 'permission':
        return permission;
      default:
        return const <AgentOption>[];
    }
  }

  static List<AgentOption> _parseList(Object? raw) {
    if (raw is! List) return const <AgentOption>[];
    return raw
        .whereType<Map>()
        .map((Map item) => AgentOption.fromJson(item.cast<String, Object?>()))
        .where((AgentOption option) => option.id.isNotEmpty)
        .toList(growable: false);
  }

  factory AgentOptionsCatalog.fromJson(Map<String, Object?> json) {
    final Map<String, bool> supports = <String, bool>{};
    final Object? rawSupports = json['supports'];
    if (rawSupports is Map) {
      rawSupports.forEach((Object? key, Object? value) {
        supports[key.toString()] = value == true;
      });
    }
    final Map<String, String> defaults = <String, String>{};
    final Object? rawDefaults = json['defaults'];
    if (rawDefaults is Map) {
      rawDefaults.forEach((Object? key, Object? value) {
        if (value is String) defaults[key.toString()] = value;
      });
    }
    return AgentOptionsCatalog(
      agent: (json['agent'] as String?)?.trim() ?? '',
      supports: supports,
      model: _parseList(json['model']),
      effort: _parseList(json['effort']),
      permission: _parseList(json['permission']),
      defaults: defaults,
    );
  }
}

/// The current selection for a workdir+agent scope: group name -> option id.
class AgentSettings {
  const AgentSettings(this.values);

  final Map<String, String> values;

  String? operator [](String group) => values[group];

  AgentSettings copyWith(String group, String id) {
    final Map<String, String> next = Map<String, String>.from(values);
    next[group] = id;
    return AgentSettings(next);
  }

  factory AgentSettings.fromJson(Map<String, Object?> json) {
    final Map<String, String> values = <String, String>{};
    json.forEach((String key, Object? value) {
      if (value is String) values[key] = value;
    });
    return AgentSettings(values);
  }

  static const AgentSettings empty = AgentSettings(<String, String>{});
}

/// Result of a `POST /api/agent-update` (CLI self-update) call.
class AgentUpdateResult {
  const AgentUpdateResult({
    required this.ok,
    required this.before,
    required this.after,
    required this.changed,
    required this.timedOut,
    required this.output,
  });

  final bool ok;
  final String before;
  final String after;
  final bool changed;
  final bool timedOut;
  final String output;

  factory AgentUpdateResult.fromJson(Map<String, Object?> json) {
    return AgentUpdateResult(
      ok: json['ok'] == true,
      before: (json['before'] as String?)?.trim() ?? '',
      after: (json['after'] as String?)?.trim() ?? '',
      changed: json['changed'] == true,
      timedOut: json['timedOut'] == true,
      output: (json['output'] as String?)?.trim() ?? '',
    );
  }
}
