import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/cli_agent.dart';

class CliAgentsController extends ChangeNotifier {
  static const String _activeAgentKey = 'agentdeck.active_cli_agent.v1';

  final List<CliAgent> _agents = defaultCliAgents;
  String _activeAgentKeyValue = defaultCliAgents.first.key;
  bool _isLoaded = false;

  List<CliAgent> get agents => List<CliAgent>.unmodifiable(_agents);
  bool get isLoaded => _isLoaded;
  String get activeAgentKey => _activeAgentKeyValue;
  CliAgent get activeAgent => cliAgentByKey(_activeAgentKeyValue);

  Future<void> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _activeAgentKeyValue =
        prefs.getString(_activeAgentKey) ?? _agents.first.key;
    if (!_agents.any((CliAgent agent) => agent.key == _activeAgentKeyValue)) {
      _activeAgentKeyValue = _agents.first.key;
    }
    _isLoaded = true;
    notifyListeners();
  }

  Future<void> setActive(String key) async {
    if (_activeAgentKeyValue == key) return;
    if (!_agents.any((CliAgent agent) => agent.key == key)) return;
    _activeAgentKeyValue = key;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeAgentKey, key);
    notifyListeners();
  }
}
