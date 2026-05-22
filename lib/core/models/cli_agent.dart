class CliAgent {
  const CliAgent({
    required this.key,
    required this.label,
    required this.description,
  });

  factory CliAgent.fromJson(Map<String, Object?> json) {
    return CliAgent(
      key: json['key'] as String? ?? 'claude',
      label: json['label'] as String? ?? 'Claude Code',
      description: json['description'] as String? ?? '',
    );
  }

  final String key;
  final String label;
  final String description;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'key': key,
      'label': label,
      'description': description,
    };
  }
}

const List<CliAgent> defaultCliAgents = <CliAgent>[
  CliAgent(
    key: 'claude',
    label: 'Claude Code',
    description: 'Anthropic Claude Code CLI',
  ),
  CliAgent(
    key: 'codex',
    label: 'Codex',
    description: 'OpenAI Codex CLI',
  ),
  CliAgent(
    key: 'agy',
    label: 'Antigravity',
    description: 'Antigravity CLI',
  ),
];

CliAgent cliAgentByKey(String? key) {
  for (final CliAgent agent in defaultCliAgents) {
    if (agent.key == key) return agent;
  }
  return defaultCliAgents.first;
}
