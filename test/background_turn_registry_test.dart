import 'package:flutter_test/flutter_test.dart';
import 'package:relay/features/chat/background_turn_registry.dart';

void main() {
  group('BackgroundTurnRegistry', () {
    test('add, take, and complete update running state', () {
      final BackgroundTurnRegistry registry = BackgroundTurnRegistry();
      const BackgroundTurn turn = BackgroundTurn(
        requestId: 'req-1',
        agentKey: 'codex',
        agentLabel: 'Codex',
        sessionId: 'session-1',
        sessionName: 'Review',
      );

      registry.add(turn);
      expect(registry.contains('codex', 'session-1'), isTrue);

      expect(registry.take('codex', 'session-1'), same(turn));
      expect(registry.contains('codex', 'session-1'), isFalse);

      registry.add(turn);
      expect(registry.complete('codex', 'session-1'), same(turn));
      expect(registry.contains('codex', 'session-1'), isFalse);
    });

    test('taken turn is no longer running and cannot complete later', () {
      final BackgroundTurnRegistry registry = BackgroundTurnRegistry();
      const BackgroundTurn turn = BackgroundTurn(
        requestId: 'req-2',
        agentKey: 'claude',
        agentLabel: 'Claude Code',
        sessionId: 'session-2',
        sessionName: 'Main',
      );

      registry.add(turn);
      final BackgroundTurn? reattached = registry.take('claude', 'session-2');

      expect(reattached, same(turn));
      expect(registry.contains('claude', 'session-2'), isFalse);
      expect(registry.complete('claude', 'session-2'), isNull);
    });

    test('unstarted foreground turn is not registered as running', () {
      final BackgroundTurnRegistry registry = BackgroundTurnRegistry();
      const BackgroundTurn turn = BackgroundTurn(
        requestId: 'req-3',
        agentKey: 'codex',
        agentLabel: 'Codex',
        sessionId: 'session-3',
        sessionName: 'Scratch',
      );

      expect(registry.add(turn, started: false), isFalse);
      expect(registry.contains('codex', 'session-3'), isFalse);
      expect(registry.complete('codex', 'session-3'), isNull);
    });
  });

  group('PendingDraftStore', () {
    test('stashed drafts restore once in order and clear after restore', () {
      final PendingDraftStore drafts = PendingDraftStore();

      drafts.stash('codex', 'session-1', <String>['first', 'second']);

      expect(drafts.contains('codex', 'session-1'), isTrue);
      expect(
        drafts.take('codex', 'session-1'),
        <String>['first', 'second'],
      );
      expect(drafts.contains('codex', 'session-1'), isFalse);
      expect(drafts.take('codex', 'session-1'), isEmpty);
    });
  });
}
