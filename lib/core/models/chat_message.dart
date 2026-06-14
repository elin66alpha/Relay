enum ChatRole { user, assistant, system }

String _newMessageId() => DateTime.now().microsecondsSinceEpoch.toString();

/// One assistant message within a single turn. A turn can produce several of
/// these — the agent's mid-task follow-up notes plus its final answer — and each
/// carries the time the backend received it so the UI can show a per-message
/// timestamp instead of collapsing everything into one block.
class MessageSegment {
  const MessageSegment({required this.text, this.createdAt});

  factory MessageSegment.fromJson(Map<String, Object?> json) {
    return MessageSegment(
      text: json['text'] as String? ?? '',
      createdAt: DateTime.tryParse(json['ts'] as String? ?? '')?.toLocal(),
    );
  }

  final String text;
  final DateTime? createdAt;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.metadata = const <String, Object?>{},
  });

  factory ChatMessage.user(String content) {
    return ChatMessage(
      id: _newMessageId(),
      role: ChatRole.user,
      content: content,
      createdAt: DateTime.now(),
    );
  }

  factory ChatMessage.assistant(
    String content, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return ChatMessage(
      id: _newMessageId(),
      role: ChatRole.assistant,
      content: content,
      createdAt: DateTime.now(),
      metadata: metadata,
    );
  }

  factory ChatMessage.fromJson(Map<String, Object?> json) {
    return ChatMessage(
      id: json['id'] as String? ?? _newMessageId(),
      role: ChatRole.values.firstWhere(
        (ChatRole r) => r.name == (json['role'] as String? ?? ''),
        orElse: () => ChatRole.assistant,
      ),
      content: json['content'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      metadata: (json['metadata'] as Map?)?.cast<String, Object?>() ??
          const <String, Object?>{},
    );
  }

  final String id;
  final ChatRole role;
  final String content;
  final DateTime createdAt;
  final Map<String, Object?> metadata;

  bool get isUser => role == ChatRole.user;

  /// The per-message segments parsed from metadata, or an empty list when this
  /// message was not split into segments (rendered as a single block then).
  List<MessageSegment> get segments {
    final Object? raw = metadata['segments'];
    if (raw is! List) return const <MessageSegment>[];
    return raw
        .whereType<Map>()
        .map((Map e) => MessageSegment.fromJson(e.cast<String, Object?>()))
        .toList(growable: false);
  }

  ChatMessage copyWith({
    String? content,
    Map<String, Object?>? metadata,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      createdAt: createdAt,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'role': role.name,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
      'metadata': metadata,
    };
  }
}
