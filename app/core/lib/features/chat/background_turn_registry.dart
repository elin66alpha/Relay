const String _sessionKeySeparator = '\u0000';

String sessionTurnKey(String agentKey, String sessionId) =>
    '$agentKey$_sessionKeySeparator$sessionId';

class BackgroundTurn {
  const BackgroundTurn({
    required this.requestId,
    required this.agentKey,
    required this.agentLabel,
    required this.sessionId,
    required this.sessionName,
    this.closeStream,
  });

  final String requestId;
  final String agentKey;
  final String agentLabel;
  final String sessionId;
  final String sessionName;
  final void Function()? closeStream;
}

class BackgroundTurnRegistry {
  final Map<String, BackgroundTurn> _turns = <String, BackgroundTurn>{};

  bool contains(String agentKey, String sessionId) {
    if (sessionId.isEmpty) return false;
    return _turns.containsKey(sessionTurnKey(agentKey, sessionId));
  }

  BackgroundTurn? get(String agentKey, String sessionId) {
    if (sessionId.isEmpty) return null;
    return _turns[sessionTurnKey(agentKey, sessionId)];
  }

  bool add(BackgroundTurn turn, {bool started = true}) {
    if (!started || turn.sessionId.isEmpty) return false;
    _turns[sessionTurnKey(turn.agentKey, turn.sessionId)] = turn;
    return true;
  }

  BackgroundTurn? take(String agentKey, String sessionId) {
    if (sessionId.isEmpty) return null;
    return _turns.remove(sessionTurnKey(agentKey, sessionId));
  }

  BackgroundTurn? complete(String agentKey, String sessionId) {
    return take(agentKey, sessionId);
  }

  List<BackgroundTurn> list() => List<BackgroundTurn>.unmodifiable(
        _turns.values,
      );

  void clear() {
    _turns.clear();
  }
}

class PendingDraftStore {
  final Map<String, List<String>> _draftsBySession = <String, List<String>>{};

  bool contains(String agentKey, String sessionId) {
    if (sessionId.isEmpty) return false;
    return _draftsBySession.containsKey(sessionTurnKey(agentKey, sessionId));
  }

  void stash(String agentKey, String sessionId, Iterable<String> drafts) {
    if (sessionId.isEmpty) return;
    final List<String> saved = drafts
        .where((String draft) => draft.trim().isNotEmpty)
        .toList(growable: false);
    final String key = sessionTurnKey(agentKey, sessionId);
    if (saved.isEmpty) {
      _draftsBySession.remove(key);
      return;
    }
    _draftsBySession[key] = saved;
  }

  List<String> take(String agentKey, String sessionId) {
    if (sessionId.isEmpty) return const <String>[];
    final List<String>? drafts = _draftsBySession.remove(
      sessionTurnKey(agentKey, sessionId),
    );
    if (drafts == null) return const <String>[];
    return List<String>.unmodifiable(drafts);
  }

  void clear() {
    _draftsBySession.clear();
  }
}
