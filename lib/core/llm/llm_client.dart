import '../models/agent.dart';
import '../models/chat_message.dart';
import '../models/llm_provider.dart';
import 'claude_client.dart';
import 'gemini_client.dart';
import 'openai_compatible_client.dart';

class LlmException implements Exception {
  LlmException(this.message, {this.status});
  final String message;
  final int? status;

  @override
  String toString() => 'LlmException(${status ?? '-'}): $message';
}

abstract class LlmClient {
  Stream<String> stream({
    required String apiKey,
    required String model,
    required String systemPrompt,
    required List<ChatMessage> history,
    double? temperature,
  });
}

LlmClient llmClientFor(Agent agent) {
  switch (agent.provider.kind) {
    case ProviderKind.claude:
      return ClaudeClient();
    case ProviderKind.gemini:
      return GeminiClient();
    case ProviderKind.openaiCompat:
      final String? baseUrl = agent.effectiveBaseUrl;
      if (baseUrl == null || baseUrl.isEmpty) {
        throw LlmException(
          '该 agent 使用自定义 provider，但没有填 base URL。请到 agent 编辑里补上。',
        );
      }
      return OpenAiCompatibleClient(baseUrl: baseUrl);
  }
}
