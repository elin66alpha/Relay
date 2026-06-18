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

/// The agents shown before the backend reports which CLIs are actually
/// installed. The live list comes from `/api/agents`; experimental agents
/// (opencode, hermes) only join it once detected on the host.
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

/// Every agent the app knows how to label, including experimental ones that may
/// not be visible yet. Used to resolve a key (from history, swarms, etc.) to a
/// display label regardless of current availability.
const List<CliAgent> knownCliAgents = <CliAgent>[
  ...defaultCliAgents,
  CliAgent(
    key: 'opencode',
    label: 'OpenCode',
    description: 'OpenCode CLI',
  ),
  CliAgent(
    key: 'hermes',
    label: 'Hermes',
    description: 'Hermes CLI',
  ),
];

CliAgent cliAgentByKey(String? key) {
  for (final CliAgent agent in knownCliAgents) {
    if (agent.key == key) return agent;
  }
  return defaultCliAgents.first;
}
