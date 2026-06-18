import 'cli_agent.dart';

/// A swarm (group chat): an ordered set of agent members sharing one transcript.
/// It pins its own [workdir] (work tree) and per-member [memberConfigs]
/// (model/effort/permission ids). Mirrors the backend `server/lib/groups.js`.
class ChatGroup {
  const ChatGroup({
    required this.id,
    required this.name,
    required this.members,
    this.workdir = '',
    this.memberConfigs = const <String, Map<String, String>>{},
  });

  factory ChatGroup.fromJson(Map<String, Object?> json) {
    final List<String> members = (json['members'] as List?)
            ?.map((Object? m) => m?.toString() ?? '')
            .where((String m) => m.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    return ChatGroup(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Swarm',
      members: members,
      workdir: json['workdir'] as String? ?? '',
      memberConfigs: _configsFrom(json['memberConfigs']),
    );
  }

  static Map<String, Map<String, String>> _configsFrom(Object? raw) {
    if (raw is! Map) return const <String, Map<String, String>>{};
    final Map<String, Map<String, String>> out =
        <String, Map<String, String>>{};
    raw.forEach((Object? key, Object? value) {
      if (value is! Map) return;
      final Map<String, String> config = <String, String>{};
      value.forEach((Object? group, Object? id) {
        if (id is String && id.isNotEmpty) config[group.toString()] = id;
      });
      if (config.isNotEmpty) out[key.toString()] = config;
    });
    return out;
  }

  final String id;
  final String name;
  final List<String> members;
  final String workdir;
  final Map<String, Map<String, String>> memberConfigs;

  /// Display labels for the members, resolving each agent key to its label.
  List<String> get memberLabels => members
      .map((String key) => cliAgentByKey(key).label)
      .toList(growable: false);
}

/// Resolve a group transcript message's author key to a human-friendly name.
/// `human` is the person; anything else is an agent key.
String groupAuthorLabel(String? author) {
  if (author == null || author.isEmpty || author == 'human') return 'You';
  return cliAgentByKey(author).label;
}
