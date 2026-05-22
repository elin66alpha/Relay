import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/agent.dart';

class AgentsStore {
  static const String _agentsKey = 'agentdeck.agents.v1';
  static const String _activeAgentKey = 'agentdeck.active_agent_id.v1';

  Future<List<Agent>> readAll() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_agentsKey);
    if (raw == null || raw.isEmpty) return <Agent>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((Map m) => Agent.fromJson(m.cast<String, Object?>()))
            .toList();
      }
    } on FormatException {
      return <Agent>[];
    }
    return <Agent>[];
  }

  Future<void> writeAll(List<Agent> agents) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _agentsKey,
      jsonEncode(agents.map((Agent a) => a.toJson()).toList()),
    );
  }

  Future<String?> readActiveAgentId() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeAgentKey);
  }

  Future<void> writeActiveAgentId(String? agentId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (agentId == null) {
      await prefs.remove(_activeAgentKey);
    } else {
      await prefs.setString(_activeAgentKey, agentId);
    }
  }
}
