import 'package:flutter_test/flutter_test.dart';

import 'package:agentdeck/core/models/agent.dart';
import 'package:agentdeck/core/models/llm_provider.dart';

void main() {
  test('parseAgentMarkdown — frontmatter form', () {
    const String md = '---\n'
        'name: Coder\n'
        'provider: claude\n'
        'model: claude-sonnet-4-5-20250929\n'
        'temperature: 0.4\n'
        '---\n'
        'You are an expert engineer.';
    final ParsedAgentMarkdown parsed = parseAgentMarkdown(md);
    expect(parsed.name, 'Coder');
    expect(parsed.provider, LlmProvider.claude);
    expect(parsed.model, 'claude-sonnet-4-5-20250929');
    expect(parsed.temperature, 0.4);
    expect(parsed.systemPrompt, 'You are an expert engineer.');
  });

  test('parseAgentMarkdown — first line as name', () {
    const String md = '# Writing Coach\n\n'
        'You are a writing coach. Ask sharp questions.';
    final ParsedAgentMarkdown parsed = parseAgentMarkdown(md);
    expect(parsed.name, 'Writing Coach');
    expect(
      parsed.systemPrompt,
      'You are a writing coach. Ask sharp questions.',
    );
    expect(parsed.provider, isNull);
  });
}
