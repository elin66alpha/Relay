import 'chat_message.dart';
import 'group.dart';

class ChatHistory {
  const ChatHistory({required this.messages, this.contextWindow});

  factory ChatHistory.fromJson(Map<String, Object?> json) {
    final List<Object?> raw = json['messages'] is List
        ? (json['messages'] as List).cast<Object?>()
        : const <Object?>[];
    final Object? window = json['contextWindow'];
    return ChatHistory(
      messages: raw
          .whereType<Map>()
          .map((Map item) => ChatMessage.fromJson(item.cast<String, Object?>()))
          .toList(growable: false),
      contextWindow: window is int && window > 0 ? window : null,
    );
  }

  final List<ChatMessage> messages;
  final int? contextWindow;
}

class ChatReply {
  const ChatReply({
    required this.requestId,
    required this.agentKey,
    required this.agentLabel,
    required this.content,
    this.segments = const <MessageSegment>[],
    this.context,
  });

  final String requestId;
  final String agentKey;
  final String agentLabel;
  final String content;
  final List<MessageSegment> segments;

  /// The reply's context size, kept as sent so it lands in message metadata.
  final Map<String, Object?>? context;
}

class ChatHistorySearchResult {
  const ChatHistorySearchResult({
    required this.agentKey,
    required this.sessionId,
    required this.sessionName,
    required this.snippet,
    required this.messageId,
  });

  factory ChatHistorySearchResult.fromJson(Map<String, Object?> json) {
    return ChatHistorySearchResult(
      agentKey: json['agentKey'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      sessionName: json['sessionName'] as String? ?? '',
      snippet: json['snippet'] as String? ?? '',
      messageId: json['messageId'] as String? ?? '',
    );
  }

  final String agentKey;
  final String sessionId;
  final String sessionName;
  final String snippet;
  final String messageId;
}

class ConversationExport {
  const ConversationExport({required this.fileName, required this.markdown});

  factory ConversationExport.fromJson(Map<String, Object?> json) {
    return ConversationExport(
      fileName: json['fileName'] as String? ?? 'relay-conversation.md',
      markdown: json['markdown'] as String? ?? '',
    );
  }

  final String fileName;
  final String markdown;
}

class GroupHistory {
  const GroupHistory({
    required this.group,
    required this.messages,
    this.runningRequestId,
  });

  final ChatGroup group;
  final List<ChatMessage> messages;

  /// The round running in this swarm, so Stop survives leaving the screen.
  final String? runningRequestId;
}
