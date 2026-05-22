import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';

class ChatHistoryStore {
  String _key(String agentId) => 'agentdeck.history.$agentId.v1';

  Future<List<ChatMessage>> read(String agentId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key(agentId));
    if (raw == null || raw.isEmpty) return <ChatMessage>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((Map m) => ChatMessage.fromJson(m.cast<String, Object?>()))
            .toList();
      }
    } on FormatException {
      return <ChatMessage>[];
    }
    return <ChatMessage>[];
  }

  Future<void> write(String agentId, List<ChatMessage> messages) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(agentId),
      jsonEncode(messages.map((ChatMessage m) => m.toJson()).toList()),
    );
  }

  Future<void> clear(String agentId) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(agentId));
  }
}
