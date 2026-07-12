// Client models for the per-agent Model / Effort / Permission / Fast controls exposed
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

/// The selectable control groups. Fast mode is advertised through [supports]
/// and rendered as a switch; the three list-based groups are parsed below.
class AgentOptionsCatalog {
  const AgentOptionsCatalog({
    required this.agent,
    required this.supports,
    required this.model,
    required this.effort,
    required this.effortByModel,
    required this.permission,
    required this.defaults,
    required this.defaultEffortByModel,
  });

  final String agent;

  /// Whether the agent supports each group at all.
  final Map<String, bool> supports;

  final List<AgentOption> model;
  final List<AgentOption> effort;

  /// Model-specific effort choices. When a selected model has an entry here,
  /// that list replaces the agent-wide [effort] fallback, including when the
  /// model explicitly supports no effort choices.
  final Map<String, List<AgentOption>> effortByModel;

  final List<AgentOption> permission;

  /// Default selection ids per group.
  final Map<String, String> defaults;

  /// Model-specific effort defaults, keyed by model id.
  final Map<String, String> defaultEffortByModel;

  bool supportsGroup(String group) {
    if (group == 'effort' &&
        effortByModel.values.any((list) => list.isNotEmpty)) {
      return true;
    }
    return supports[group] == true;
  }

  List<AgentOption> optionsFor(String group, {String? modelId}) {
    switch (group) {
      case 'model':
        return model;
      case 'effort':
        if (modelId != null && effortByModel.containsKey(modelId)) {
          return effortByModel[modelId]!;
        }
        return effort;
      case 'permission':
        return permission;
      default:
        return const <AgentOption>[];
    }
  }

  String? defaultFor(String group, {String? modelId}) {
    if (group == 'effort' && modelId != null) {
      return defaultEffortByModel[modelId] ?? defaults[group];
    }
    return defaults[group];
  }

  /// Keeps [selected] when it is valid for the current model, otherwise falls
  /// back to a valid catalog default and then the first available choice.
  String? resolveSelection(
    String group,
    String? selected, {
    String? modelId,
  }) {
    final List<AgentOption> options = optionsFor(group, modelId: modelId);
    if (selected != null &&
        options.any((AgentOption option) => option.id == selected)) {
      return selected;
    }
    final String? fallback = defaultFor(group, modelId: modelId);
    if (fallback != null &&
        options.any((AgentOption option) => option.id == fallback)) {
      return fallback;
    }
    return options.isEmpty ? null : options.first.id;
  }

  static List<AgentOption> _parseList(Object? raw) {
    if (raw is! List) return const <AgentOption>[];
    return raw
        .whereType<Map>()
        .map((Map item) => AgentOption.fromJson(item.cast<String, Object?>()))
        .where((AgentOption option) => option.id.isNotEmpty)
        .toList(growable: false);
  }

  static Map<String, List<AgentOption>> _parseOptionMap(Object? raw) {
    final Map<String, List<AgentOption>> result = <String, List<AgentOption>>{};
    if (raw is! Map) return result;
    raw.forEach((Object? key, Object? value) {
      final String modelId = key.toString().trim();
      if (modelId.isEmpty || value is! List) return;
      result[modelId] = _parseList(value);
    });
    return result;
  }

  static Map<String, String> _parseStringMap(Object? raw) {
    final Map<String, String> result = <String, String>{};
    if (raw is! Map) return result;
    raw.forEach((Object? key, Object? value) {
      final String mapKey = key.toString().trim();
      if (mapKey.isEmpty || value is! String) return;
      final String mapValue = value.trim();
      if (mapValue.isNotEmpty) result[mapKey] = mapValue;
    });
    return result;
  }

  factory AgentOptionsCatalog.fromJson(Map<String, Object?> json) {
    final Map<String, bool> supports = <String, bool>{};
    final Object? rawSupports = json['supports'];
    if (rawSupports is Map) {
      rawSupports.forEach((Object? key, Object? value) {
        supports[key.toString()] = value == true;
      });
    }
    final Map<String, String> defaults = _parseStringMap(json['defaults']);
    return AgentOptionsCatalog(
      agent: (json['agent'] as String?)?.trim() ?? '',
      supports: supports,
      model: _parseList(json['model']),
      effort: _parseList(json['effort']),
      effortByModel: _parseOptionMap(json['effortByModel']),
      permission: _parseList(json['permission']),
      defaults: defaults,
      defaultEffortByModel: _parseStringMap(json['defaultEffortByModel']),
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
