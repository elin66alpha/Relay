/// A Card Mode suggestion, mirroring the backend card schema in
/// `server/lib/cards.js`. Cards are derived from chat history and acted on with
/// four-directional swipe gestures.
class CardModel {
  const CardModel({
    required this.id,
    required this.agentKey,
    required this.title,
    required this.reason,
    required this.prompt,
    required this.confidence,
    required this.source,
    required this.status,
    this.deferUntil,
    this.createdAt,
    this.updatedAt,
  });

  factory CardModel.fromJson(Map<String, Object?> json) {
    DateTime? parse(Object? value) =>
        value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;
    return CardModel(
      id: json['id'] as String? ?? '',
      agentKey: json['agentKey'] as String? ?? 'claude',
      title: json['title'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      source: json['source'] as String? ?? '',
      status: json['status'] as String? ?? 'pending',
      deferUntil: parse(json['deferUntil']),
      createdAt: parse(json['createdAt']),
      updatedAt: parse(json['updatedAt']),
    );
  }

  final String id;
  final String agentKey;
  final String title;
  final String reason;
  final String prompt;
  final double confidence;
  final String source;
  final String status;
  final DateTime? deferUntil;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isFromChat => source == 'chat_history';

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'agentKey': agentKey,
      'title': title,
      'reason': reason,
      'prompt': prompt,
      'confidence': confidence,
      'source': source,
      'status': status,
      'deferUntil': deferUntil?.toIso8601String(),
      'createdAt': createdAt?.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }
}
