import 'dart:convert';

import 'package:cryptography/dart.dart';

import 'cli_agent.dart';
import 'machine_credential.dart';

/// Another Relay backend that remote members of a swarm run on.
class SwarmPeer {
  const SwarmPeer({required this.name, required this.baseUrl});

  final String name;
  final String baseUrl;
}

final RegExp _remoteMemberKey = RegExp(r'^([0-9a-f]{12}):(.+)$');

/// The peer id of a remote member key `<peerId>:<agentKey>`, or null for a
/// member on the swarm's own machine.
String? memberPeerId(String key) => _remoteMemberKey.firstMatch(key)?.group(1);

/// The agent key a member runs, on whichever machine it is.
String memberAgentKey(String key) =>
    _remoteMemberKey.firstMatch(key)?.group(2) ?? key;

/// A backend address as the backend stores it for a peer: scheme, lower-case
/// host, non-default port and path without a trailing slash. Mirrors
/// `normalizeBaseUrl` in `server/lib/peer-client.js`.
String normalizePeerBaseUrl(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return '';
  }
  final String scheme = uri.scheme.toLowerCase();
  final String host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  final bool defaultPort = !uri.hasPort ||
      (scheme == 'http' && uri.port == 80) ||
      (scheme == 'https' && uri.port == 443);
  final String path = uri.path.replaceAll(RegExp(r'/+$'), '');
  return '$scheme://${host.toLowerCase()}${defaultPort ? '' : ':${uri.port}'}$path';
}

/// The id the backend derives for a peer from its address (first 12 hex
/// digits of its SHA-256), so a remote member key can be built here.
String peerIdForBaseUrl(String baseUrl) {
  final List<int> digest = const DartSha256()
      .hashSync(utf8.encode(normalizePeerBaseUrl(baseUrl)))
      .bytes;
  return digest
      .take(6)
      .map((int b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

/// This device's credentials for the machines the given members run on. They
/// travel with each swarm request that reaches those machines; a machine this
/// device has no credential for is simply left out.
List<MachineCredential> peerCredentialsFor(
  Iterable<String> members,
  Iterable<MachineCredential> machines,
) {
  final Set<String> peerIds =
      members.map(memberPeerId).whereType<String>().toSet();
  if (peerIds.isEmpty) return const <MachineCredential>[];
  return machines
      .where(
        (MachineCredential m) => peerIds.contains(peerIdForBaseUrl(m.baseUrl)),
      )
      .toList(growable: false);
}

/// A swarm (group chat): an ordered set of agent members sharing one transcript.
/// It pins its own [workdir] (work tree) and per-member [memberConfigs]
/// (model/effort/permission/fast ids). A remote member's config holds its
/// `workdir` and `sessionId` on its machine, which [peers] names. Mirrors
/// `server/lib/groups.js`.
class ChatGroup {
  const ChatGroup({
    required this.id,
    required this.name,
    required this.members,
    this.workdir = '',
    this.memberConfigs = const <String, Map<String, String>>{},
    this.peers = const <String, SwarmPeer>{},
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
      peers: _peersFrom(json['peers']),
    );
  }

  static Map<String, SwarmPeer> _peersFrom(Object? raw) {
    if (raw is! Map) return const <String, SwarmPeer>{};
    final Map<String, SwarmPeer> out = <String, SwarmPeer>{};
    raw.forEach((Object? id, Object? value) {
      if (value is! Map) return;
      final Object? baseUrl = value['baseUrl'];
      if (baseUrl is! String || baseUrl.isEmpty) return;
      final Object? name = value['name'];
      out[id.toString()] = SwarmPeer(
        name: name is String && name.isNotEmpty ? name : baseUrl,
        baseUrl: baseUrl,
      );
    });
    return out;
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
  final Map<String, SwarmPeer> peers;

  /// The machine a remote member runs on; null for a member on this machine.
  SwarmPeer? peerOf(String member) {
    final String? peerId = memberPeerId(member);
    return peerId == null ? null : peers[peerId];
  }

  /// A member's default name: its agent's label, followed by its machine's
  /// name for a remote member, so the same agent on two machines reads apart.
  String memberLabel(String member) {
    final String label = cliAgentByKey(memberAgentKey(member)).label;
    final String? peerId = memberPeerId(member);
    if (peerId == null) return label;
    return '$label (${peers[peerId]?.name ?? peerId})';
  }

  /// Display labels for the members.
  List<String> get memberLabels =>
      members.map(memberLabel).toList(growable: false);
}

/// Resolve a group transcript message's author key to a human-friendly name.
/// `human` is the person; anything else is a member key.
String groupAuthorLabel(String? author) {
  if (author == null || author.isEmpty || author == 'human') return 'You';
  return cliAgentByKey(memberAgentKey(author)).label;
}
