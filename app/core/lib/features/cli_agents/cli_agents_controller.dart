import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/cli_agent.dart';

class CliAgentsController extends ChangeNotifier {
  static const String _activeAgentKey = 'relay.active_cli_agent.v1';

  // Starts with the built-in agents and is replaced by the backend's live list
  // with per-host install/auth status.
  List<CliAgent> _agents = defaultCliAgents;
  String _activeAgentKeyValue = defaultCliAgents.first.key;
  bool _isLoaded = false;

  List<CliAgent> get agents => List<CliAgent>.unmodifiable(_agents);
  bool get isLoaded => _isLoaded;
  String get activeAgentKey => _activeAgentKeyValue;
  CliAgent get activeAgent => _agentForKey(_activeAgentKeyValue);

  Future<void> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _activeAgentKeyValue =
        prefs.getString(_activeAgentKey) ?? _agents.first.key;
    _ensureSelectableActiveAgent();
    _isLoaded = true;
    notifyListeners();
  }

  /// Replace the agent list with the backend's live set. Keeps the current
  /// selection when it still exists; otherwise falls back to the first agent.
  void syncAgents(List<CliAgent> agents) {
    if (agents.isEmpty) return;
    if (listEquals(agents, _agents)) return;
    _agents = List<CliAgent>.unmodifiable(agents);
    _ensureSelectableActiveAgent();
    notifyListeners();
  }

  Future<bool> setActive(String key) async {
    if (_activeAgentKeyValue == key) {
      return isCliAgentSelectable(activeAgent);
    }
    final CliAgent? next = _findAgent(key);
    if (next == null || !isCliAgentSelectable(next)) return false;
    _activeAgentKeyValue = key;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeAgentKey, key);
    notifyListeners();
    return true;
  }

  CliAgent _agentForKey(String key) {
    return _findAgent(key) ?? cliAgentByKey(key);
  }

  CliAgent? _findAgent(String key) {
    for (final CliAgent agent in _agents) {
      if (agent.key == key) return agent;
    }
    return null;
  }

  void _ensureSelectableActiveAgent() {
    final CliAgent? current = _findAgent(_activeAgentKeyValue);
    if (current != null && isCliAgentSelectable(current)) return;
    _activeAgentKeyValue = _fallbackAgent().key;
  }

  CliAgent _fallbackAgent() {
    for (final CliAgent agent in _agents) {
      if (isCliAgentSelectable(agent)) return agent;
    }
    return _agents.first;
  }
}
