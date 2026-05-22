import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import 'llm_client.dart';

class ClaudeClient implements LlmClient {
  ClaudeClient({String? baseUrl, http.Client? httpClient})
      : _baseUrl = baseUrl ?? 'https://api.anthropic.com/v1',
        _http = httpClient ?? http.Client();

  final String _baseUrl;
  final http.Client _http;

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required String systemPrompt,
    required List<ChatMessage> history,
    double? temperature,
  }) async* {
    final Uri uri = Uri.parse('$_baseUrl/messages');
    final Map<String, Object?> body = <String, Object?>{
      'model': model,
      'max_tokens': 4096,
      'stream': true,
      'messages': _toClaudeMessages(history),
    };
    if (systemPrompt.trim().isNotEmpty) {
      body['system'] = systemPrompt;
    }
    if (temperature != null) body['temperature'] = temperature;

    final http.Request request = http.Request('POST', uri);
    request.headers.addAll(<String, String>{
      'content-type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
      'anthropic-dangerous-direct-browser-access': 'true',
    });
    request.body = jsonEncode(body);

    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } catch (e) {
      throw LlmException('network error: $e');
    }

    if (response.statusCode >= 400) {
      final String text = await response.stream.bytesToString();
      throw LlmException(
        _extractErrorMessage(text),
        status: response.statusCode,
      );
    }

    final Stream<String> lines =
        response.stream.transform(utf8.decoder).transform(const LineSplitter());

    await for (final String line in lines) {
      if (!line.startsWith('data:')) continue;
      final String payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      try {
        final Object? decoded = jsonDecode(payload);
        if (decoded is! Map) continue;
        final String? type = decoded['type'] as String?;
        if (type == 'content_block_delta') {
          final Map? delta = decoded['delta'] as Map?;
          if (delta?['type'] == 'text_delta') {
            final String? text = delta?['text'] as String?;
            if (text != null && text.isNotEmpty) yield text;
          }
        } else if (type == 'message_stop') {
          return;
        } else if (type == 'error') {
          final Map? error = decoded['error'] as Map?;
          throw LlmException(
            (error?['message'] as String?) ?? 'stream error',
          );
        }
      } on FormatException {
        continue;
      }
    }
  }

  List<Map<String, Object?>> _toClaudeMessages(List<ChatMessage> history) {
    return history
        .where(
          (ChatMessage m) =>
              m.role != ChatRole.system && m.content.trim().isNotEmpty,
        )
        .map(
          (ChatMessage m) => <String, Object?>{
            'role': m.isUser ? 'user' : 'assistant',
            'content': m.content,
          },
        )
        .toList();
  }

  String _extractErrorMessage(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map) {
        final Map? error = decoded['error'] as Map?;
        final String? msg = error?['message'] as String?;
        if (msg != null && msg.isNotEmpty) return msg;
      }
    } on FormatException {
      // fall through
    }
    return body.isEmpty ? 'request failed' : body;
  }
}
