import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import 'llm_client.dart';

class OpenAiCompatibleClient implements LlmClient {
  OpenAiCompatibleClient({
    required this.baseUrl,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  @override
  Stream<String> stream({
    required String apiKey,
    required String model,
    required String systemPrompt,
    required List<ChatMessage> history,
    double? temperature,
  }) async* {
    final Uri uri = Uri.parse('$baseUrl/chat/completions');
    final List<Map<String, Object?>> messages = <Map<String, Object?>>[];
    if (systemPrompt.trim().isNotEmpty) {
      messages.add(<String, Object?>{
        'role': 'system',
        'content': systemPrompt,
      });
    }
    for (final ChatMessage m in history) {
      if (m.content.trim().isEmpty) continue;
      messages.add(<String, Object?>{
        'role': m.isUser ? 'user' : 'assistant',
        'content': m.content,
      });
    }

    final Map<String, Object?> body = <String, Object?>{
      'model': model,
      'messages': messages,
      'stream': true,
    };
    if (temperature != null) body['temperature'] = temperature;

    final http.Request request = http.Request('POST', uri);
    request.headers.addAll(<String, String>{
      'content-type': 'application/json',
      'authorization': 'Bearer $apiKey',
      'accept': 'text/event-stream',
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
      if (payload == '[DONE]') return;
      try {
        final Object? decoded = jsonDecode(payload);
        if (decoded is! Map) continue;
        final List? choices = decoded['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final Map? first = choices.first as Map?;
        final Map? delta = first?['delta'] as Map?;
        final String? content = delta?['content'] as String?;
        if (content != null && content.isNotEmpty) yield content;
      } on FormatException {
        continue;
      }
    }
  }

  String _extractErrorMessage(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map) {
        final Object? error = decoded['error'];
        if (error is Map) {
          final String? msg = error['message'] as String?;
          if (msg != null && msg.isNotEmpty) return msg;
        } else if (error is String && error.isNotEmpty) {
          return error;
        }
      }
    } on FormatException {
      // fall through
    }
    return body.isEmpty ? 'request failed' : body;
  }
}
