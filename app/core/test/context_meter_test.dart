import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/models/chat_message.dart';
import 'package:relay_core/features/chat/context_meter.dart';

ChatMessage _reply(Object? context) => ChatMessage.assistant(
      'reply',
      metadata: <String, Object?>{if (context != null) 'context': context},
    );

void main() {
  test('empty and first-streaming conversations start at zero', () {
    expect(
      contextMeterUsage(<ChatMessage>[], contextWindow: 200000),
      (used: 0, size: 200000),
    );
    expect(
      contextMeterUsage(
        <ChatMessage>[
          ChatMessage.user('hi'),
          ChatMessage.assistant(
            'partial',
            metadata: <String, Object?>{'streaming': true},
          ),
        ],
        contextWindow: 200000,
      ),
      (used: 0, size: 200000),
    );
  });

  test('finished replies without context have unknown usage', () {
    expect(
      contextMeterUsage(<ChatMessage>[_reply(null)], contextWindow: 200000),
      (used: null, size: 200000),
    );
    expect(
      contextMeterUsage(
        <ChatMessage>[
          ChatMessage(
            id: 'system',
            role: ChatRole.system,
            content: 'notice',
            createdAt: DateTime.utc(2026),
          ),
        ],
        contextWindow: 200000,
      ),
      (used: 0, size: 200000),
    );
  });

  test('the latest reported context overrides the remembered window', () {
    expect(
      contextMeterUsage(
        <ChatMessage>[
          _reply(<String, Object?>{'used': 1000, 'size': 200000}),
          _reply(<String, Object?>{'used': 4200, 'size': 400000}),
          _reply(null),
        ],
        contextWindow: 1000000,
      ),
      (used: 4200, size: 400000),
    );
  });

  test('an unreported window stays unknown for empty and old conversations', () {
    expect(contextMeterUsage(<ChatMessage>[]), (used: 0, size: null));
    expect(
      contextMeterUsage(<ChatMessage>[_reply(null)]),
      (used: null, size: null),
    );
  });

  test('history parses a window and accepts older backends without one', () {
    final ChatHistory history = ChatHistory.fromJson(<String, Object?>{
      'messages': <Object?>[_reply(null).toJson()],
      'contextWindow': 200000,
    });
    expect(history.messages.single.content, 'reply');
    expect(history.contextWindow, 200000);
    expect(ChatHistory.fromJson(<String, Object?>{}).contextWindow, isNull);
    for (final Object? window in <Object?>[null, 0, -1, '200000']) {
      expect(
        ChatHistory.fromJson(<String, Object?>{'contextWindow': window})
            .contextWindow,
        isNull,
      );
    }
  });

  test('the latest reported size wins; a streaming reply keeps the previous one',
      () {
    final List<ChatMessage> messages = <ChatMessage>[
      _reply(<String, Object?>{'used': 1000, 'size': 200000}),
      _reply(<String, Object?>{'used': 4200, 'size': 200000}),
      ChatMessage.user('next'),
      _reply(null),
    ];
    expect(latestContextUsage(messages), (used: 4200, size: 200000));
    expect(latestContextUsage(<ChatMessage>[ChatMessage.user('hi')]), isNull);
  });

  test('a malformed size is treated as unreported', () {
    expect(_reply(<String, Object?>{'used': 5, 'size': 0}).contextUsage, isNull);
    expect(
      _reply(<String, Object?>{'used': '5', 'size': 10}).contextUsage,
      isNull,
    );
    expect(_reply('nope').contextUsage, isNull);
  });

  test('token counts read compactly', () {
    expect(formatTokenCount(850), '850');
    expect(formatTokenCount(11377), '11k');
    expect(formatTokenCount(258400), '258k');
    expect(formatTokenCount(1000000), '1M');
    expect(formatTokenCount(1500000), '1.5M');
  });
}
