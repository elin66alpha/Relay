import 'package:flutter_test/flutter_test.dart';
import 'package:relay/features/chat/chat_content.dart';

void main() {
  group('parseOptionPrompt', () {
    test('detects a question followed by a trailing ordered list', () {
      final List<String>? options = parseOptionPrompt(
        'Which database should we use?\n'
        '1. PostgreSQL\n'
        '2. MySQL\n'
        '3. SQLite\n',
      );
      expect(options, <String>['PostgreSQL', 'MySQL', 'SQLite']);
    });

    test('strips inline markdown from option labels', () {
      final List<String>? options = parseOptionPrompt(
        '怎么处理？\n'
        '1. **保留** 现有逻辑\n'
        '2. `重写` 模块\n',
      );
      expect(options, <String>['保留 现有逻辑', '重写 模块']);
    });

    test('supports a) b) style and full-width question mark', () {
      final List<String>? options = parseOptionPrompt(
        '你想用哪个方案？\n'
        'a) 方案甲\n'
        'b) 方案乙\n',
      );
      expect(options, <String>['方案甲', '方案乙']);
    });

    test('returns null for an ordered list with no preceding question', () {
      final List<String>? options = parseOptionPrompt(
        'Here are the steps:\n'
        '1. Install deps\n'
        '2. Run build\n',
      );
      expect(options, isNull);
    });

    test('returns null when the list is not at the very end', () {
      final List<String>? options = parseOptionPrompt(
        'Which one?\n'
        '1. A\n'
        '2. B\n'
        'Let me know.\n',
      );
      expect(options, isNull);
    });

    test('returns null for a single-item list', () {
      final List<String>? options = parseOptionPrompt(
        'Proceed?\n'
        '1. Yes\n',
      );
      expect(options, isNull);
    });
  });

  group('splitLeadingPlan', () {
    test('folds leading "I will" plan paragraphs off the answer', () {
      final ({String plan, String body})? split = splitLeadingPlan(
        'I will read the config and patch the parser.\n\n'
        "I'll also add a test.\n\n"
        'The bug was a missing null check; here is the fix.',
      );
      expect(split, isNotNull);
      expect(split!.plan, contains('I will read the config'));
      expect(split.plan, contains("I'll also add a test"));
      expect(split.body, 'The bug was a missing null check; here is the fix.');
    });

    test('handles Chinese plan preambles', () {
      final ({String plan, String body})? split = splitLeadingPlan(
        '我将先检查日志，然后定位问题。\n\n'
        '结论：是 token 过期导致的。',
      );
      expect(split, isNotNull);
      expect(split!.body, '结论：是 token 过期导致的。');
    });

    test('returns null when there is no plan preamble', () {
      final ({String plan, String body})? split = splitLeadingPlan(
        'Here is the answer.\n\nIt has two paragraphs.',
      );
      expect(split, isNull);
    });

    test('returns null when the message is only a plan', () {
      final ({String plan, String body})? split = splitLeadingPlan(
        'I will do step one.\n\nI will do step two.',
      );
      expect(split, isNull);
    });
  });
}
