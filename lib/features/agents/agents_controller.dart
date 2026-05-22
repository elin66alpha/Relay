import 'package:flutter/foundation.dart';

import '../../core/models/agent.dart';
import '../../core/storage/agents_store.dart';
import '../../core/storage/chat_history_store.dart';

class AgentsController extends ChangeNotifier {
  AgentsController({
    AgentsStore? store,
    ChatHistoryStore? historyStore,
  })  : _store = store ?? AgentsStore(),
        _historyStore = historyStore ?? ChatHistoryStore();

  final AgentsStore _store;
  final ChatHistoryStore _historyStore;

  List<Agent> _agents = <Agent>[];
  String? _activeAgentId;
  bool _isLoaded = false;

  List<Agent> get agents => List<Agent>.unmodifiable(_agents);
  bool get isLoaded => _isLoaded;
  String? get activeAgentId => _activeAgentId;

  Agent? get activeAgent {
    if (_activeAgentId == null) return null;
    for (final Agent a in _agents) {
      if (a.id == _activeAgentId) return a;
    }
    return null;
  }

  Future<void> load() async {
    _agents = await _store.readAll();
    _activeAgentId = await _store.readActiveAgentId();
    if (_activeAgentId != null &&
        !_agents.any((Agent a) => a.id == _activeAgentId)) {
      _activeAgentId = null;
    }
    if (_activeAgentId == null && _agents.isNotEmpty) {
      _activeAgentId = _agents.first.id;
      await _store.writeActiveAgentId(_activeAgentId);
    }
    _isLoaded = true;
    notifyListeners();
  }

  Future<Agent> add(Agent agent) async {
    _agents = <Agent>[..._agents, agent];
    await _store.writeAll(_agents);
    if (_activeAgentId == null) {
      _activeAgentId = agent.id;
      await _store.writeActiveAgentId(_activeAgentId);
    }
    notifyListeners();
    return agent;
  }

  Future<void> update(Agent agent) async {
    _agents = _agents
        .map((Agent a) => a.id == agent.id ? agent : a)
        .toList(growable: false);
    await _store.writeAll(_agents);
    notifyListeners();
  }

  Future<void> remove(String agentId) async {
    _agents = _agents.where((Agent a) => a.id != agentId).toList();
    await _historyStore.clear(agentId);
    if (_activeAgentId == agentId) {
      _activeAgentId = _agents.isNotEmpty ? _agents.first.id : null;
      await _store.writeActiveAgentId(_activeAgentId);
    }
    await _store.writeAll(_agents);
    notifyListeners();
  }

  Future<void> setActive(String agentId) async {
    if (_activeAgentId == agentId) return;
    if (!_agents.any((Agent a) => a.id == agentId)) return;
    _activeAgentId = agentId;
    await _store.writeActiveAgentId(agentId);
    notifyListeners();
  }
}
