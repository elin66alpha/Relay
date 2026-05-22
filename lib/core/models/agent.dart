import 'llm_provider.dart';

class Agent {
  const Agent({
    required this.id,
    required this.name,
    required this.systemPrompt,
    required this.provider,
    required this.model,
    required this.createdAt,
    this.temperature,
    this.baseUrlOverride,
  });

  factory Agent.create({
    required String name,
    required String systemPrompt,
    required LlmProvider provider,
    required String model,
    double? temperature,
    String? baseUrlOverride,
  }) {
    return Agent(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      systemPrompt: systemPrompt,
      provider: provider,
      model: model.trim().isEmpty ? provider.defaultModel : model,
      temperature: temperature,
      baseUrlOverride: _normalizeBaseUrl(baseUrlOverride),
      createdAt: DateTime.now(),
    );
  }

  factory Agent.fromJson(Map<String, Object?> json) {
    return Agent(
      id: json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? 'Unnamed',
      systemPrompt: json['systemPrompt'] as String? ?? '',
      provider: llmProviderFromName(json['provider'] as String?),
      model: json['model'] as String? ?? LlmProvider.claude.defaultModel,
      temperature: (json['temperature'] as num?)?.toDouble(),
      baseUrlOverride: _normalizeBaseUrl(json['baseUrlOverride'] as String?),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  final String id;
  final String name;
  final String systemPrompt;
  final LlmProvider provider;
  final String model;
  final double? temperature;
  final String? baseUrlOverride;
  final DateTime createdAt;

  /// Effective base URL — override if set, otherwise the provider's default.
  /// Returns null for providers that don't use a base URL (e.g. `custom` with
  /// no override set, which is an invalid state surfaced when sending).
  String? get effectiveBaseUrl => baseUrlOverride ?? provider.baseUrl;

  Agent copyWith({
    String? name,
    String? systemPrompt,
    LlmProvider? provider,
    String? model,
    double? temperature,
    String? baseUrlOverride,
    bool clearBaseUrlOverride = false,
  }) {
    return Agent(
      id: id,
      name: name ?? this.name,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      provider: provider ?? this.provider,
      model: model ?? this.model,
      temperature: temperature ?? this.temperature,
      baseUrlOverride: clearBaseUrlOverride
          ? null
          : _normalizeBaseUrl(baseUrlOverride ?? this.baseUrlOverride),
      createdAt: createdAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'systemPrompt': systemPrompt,
      'provider': provider.name,
      'model': model,
      'temperature': temperature,
      'baseUrlOverride': baseUrlOverride,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}

String? _normalizeBaseUrl(String? raw) {
  if (raw == null) return null;
  final String trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

/// Parses a markdown agent definition.
///
/// Supports optional YAML-like frontmatter:
///   ---
///   name: My Agent
///   provider: kimi
///   model: kimi-latest
///   temperature: 0.7
///   baseUrl: https://api.moonshot.cn/v1
///   ---
///   <system prompt body>
///
/// Without frontmatter, the first non-empty line is treated as the name and
/// the remainder as the system prompt.
class ParsedAgentMarkdown {
  const ParsedAgentMarkdown({
    required this.name,
    required this.systemPrompt,
    this.provider,
    this.model,
    this.temperature,
    this.baseUrlOverride,
  });

  final String name;
  final String systemPrompt;
  final LlmProvider? provider;
  final String? model;
  final double? temperature;
  final String? baseUrlOverride;
}

ParsedAgentMarkdown parseAgentMarkdown(String raw) {
  final String text = raw.replaceAll('\r\n', '\n').trimLeft();

  if (text.startsWith('---\n') || text.startsWith('---\r\n')) {
    final int closing = text.indexOf('\n---', 4);
    if (closing != -1) {
      final String frontmatter = text.substring(4, closing);
      final String body = text.substring(closing + 4).trimLeft();
      final Map<String, String> fields = _parseSimpleFrontmatter(frontmatter);
      final String name = fields['name']?.trim().isNotEmpty == true
          ? fields['name']!.trim()
          : _firstLineOf(body);
      final String systemPrompt =
          fields['name'] != null ? body.trim() : _bodyWithoutFirstLine(body);
      return ParsedAgentMarkdown(
        name: name.isEmpty ? 'Unnamed' : name,
        systemPrompt: systemPrompt,
        provider: fields['provider'] != null
            ? llmProviderFromName(fields['provider'])
            : null,
        model: fields['model']?.trim(),
        temperature: double.tryParse(fields['temperature'] ?? ''),
        baseUrlOverride:
            fields['baseurl'] ?? fields['base_url'] ?? fields['endpoint'],
      );
    }
  }

  final String name = _firstLineOf(text);
  final String body = _bodyWithoutFirstLine(text);
  return ParsedAgentMarkdown(
    name: name.isEmpty ? 'Unnamed' : name,
    systemPrompt: body,
  );
}

String _firstLineOf(String text) {
  for (final String line in text.split('\n')) {
    final String stripped = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    if (stripped.isNotEmpty) return stripped;
  }
  return '';
}

String _bodyWithoutFirstLine(String text) {
  final List<String> lines = text.split('\n');
  int skipUntil = -1;
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].trim().isNotEmpty) {
      skipUntil = i;
      break;
    }
  }
  if (skipUntil == -1) return '';
  return lines.sublist(skipUntil + 1).join('\n').trim();
}

Map<String, String> _parseSimpleFrontmatter(String text) {
  final Map<String, String> out = <String, String>{};
  for (final String line in text.split('\n')) {
    final int colon = line.indexOf(':');
    if (colon <= 0) continue;
    final String key = line.substring(0, colon).trim().toLowerCase();
    String value = line.substring(colon + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    if (key.isNotEmpty) out[key] = value;
  }
  return out;
}
