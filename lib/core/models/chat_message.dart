enum ChatRole { user, assistant, system }

String _newMessageId() => DateTime.now().microsecondsSinceEpoch.toString();

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
