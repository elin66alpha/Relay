import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import 'llm_client.dart';

class GeminiClient implements LlmClient {
  GeminiClient({String? baseUrl, http.Client? httpClient})
      : _baseUrl =
            baseUrl ?? 'https://generativelanguage.googleapis.com/v1beta',
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
    final Uri uri = Uri.parse(
      '$_baseUrl/models/$model:streamGenerateContent?alt=sse&key=$apiKey',
    );

    final List<Map<String, Object?>> contents = <Map<String, Object?>>[];
    for (final ChatMessage m in history) {
      if (m.content.trim().isEmpty) continue;
      contents.add(<String, Object?>{
        'role': m.isUser ? 'user' : 'model',
        'parts': <Map<String, Object?>>[
          <String, Object?>{'text': m.content},
        ],
      });
    }

    final Map<String, Object?> body = <String, Object?>{
      'contents': contents,
    };
    if (systemPrompt.trim().isNotEmpty) {
      body['systemInstruction'] = <String, Object?>{
        'parts': <Map<String, Object?>>[
          <String, Object?>{'text': systemPrompt},
        ],
      };
    }
    if (temperature != null) {
      body['generationConfig'] = <String, Object?>{'temperature': temperature};
    }

    final http.Request request = http.Request('POST', uri);
    request.headers.addAll(<String, String>{
      'content-type': 'application/json',
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
        final List? candidates = decoded['candidates'] as List?;
        if (candidates == null || candidates.isEmpty) continue;
        final Map? content = (candidates.first as Map?)?['content'] as Map?;
        final List? parts = content?['parts'] as List?;
        if (parts == null) continue;
        for (final Object? part in parts) {
          if (part is Map) {
            final String? text = part['text'] as String?;
            if (text != null && text.isNotEmpty) yield text;
          }
        }
      } on FormatException {
        continue;
      }
    }
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
