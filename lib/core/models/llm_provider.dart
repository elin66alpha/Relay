/// API shape a provider uses. Determines which LlmClient implementation
/// handles requests for it.
enum ProviderKind { claude, openaiCompat, gemini }

/// 国际 / 中文 / 其他 — used to group providers in the settings list.
enum ProviderRegion { international, china, other }

enum LlmProvider {
  // International
  claude,
  openai,
  gemini,
  mistral,
  groq,
  xai,
  openrouter,
  perplexity,
  together,
  fireworks,
  // China
  deepseek,
  kimi,
  qwen,
  doubao,
  zhipu,
  yi,
  stepfun,
  minimax,
  // Other
  custom,
}

extension LlmProviderInfo on LlmProvider {
  String get label {
    return switch (this) {
      LlmProvider.claude => 'Claude',
      LlmProvider.openai => 'OpenAI',
      LlmProvider.gemini => 'Gemini',
      LlmProvider.mistral => 'Mistral',
      LlmProvider.groq => 'Groq',
      LlmProvider.xai => 'xAI (Grok)',
      LlmProvider.openrouter => 'OpenRouter',
      LlmProvider.perplexity => 'Perplexity',
      LlmProvider.together => 'Together AI',
      LlmProvider.fireworks => 'Fireworks',
      LlmProvider.deepseek => 'DeepSeek',
      LlmProvider.kimi => 'Kimi (Moonshot)',
      LlmProvider.qwen => 'Qwen (通义千问)',
      LlmProvider.doubao => 'Doubao (豆包)',
      LlmProvider.zhipu => 'Zhipu GLM (智谱)',
      LlmProvider.yi => 'Yi (零一万物)',
      LlmProvider.stepfun => 'StepFun (阶跃星辰)',
      LlmProvider.minimax => 'MiniMax',
      LlmProvider.custom => '自定义 (OpenAI-compatible)',
    };
  }

  ProviderKind get kind {
    return switch (this) {
      LlmProvider.claude => ProviderKind.claude,
      LlmProvider.gemini => ProviderKind.gemini,
      _ => ProviderKind.openaiCompat,
    };
  }

  ProviderRegion get region {
    return switch (this) {
      LlmProvider.claude ||
      LlmProvider.openai ||
      LlmProvider.gemini ||
      LlmProvider.mistral ||
      LlmProvider.groq ||
      LlmProvider.xai ||
      LlmProvider.openrouter ||
      LlmProvider.perplexity ||
      LlmProvider.together ||
      LlmProvider.fireworks =>
        ProviderRegion.international,
      LlmProvider.deepseek ||
      LlmProvider.kimi ||
      LlmProvider.qwen ||
      LlmProvider.doubao ||
      LlmProvider.zhipu ||
      LlmProvider.yi ||
      LlmProvider.stepfun ||
      LlmProvider.minimax =>
        ProviderRegion.china,
      LlmProvider.custom => ProviderRegion.other,
    };
  }

  /// Default base URL for OpenAI-compatible providers. Claude and Gemini have
  /// their own client implementations and ignore this value (it's only kept
  /// here for completeness / for tests).
  String? get baseUrl {
    return switch (this) {
      LlmProvider.claude => 'https://api.anthropic.com/v1',
      LlmProvider.openai => 'https://api.openai.com/v1',
      LlmProvider.gemini => 'https://generativelanguage.googleapis.com/v1beta',
      LlmProvider.mistral => 'https://api.mistral.ai/v1',
      LlmProvider.groq => 'https://api.groq.com/openai/v1',
      LlmProvider.xai => 'https://api.x.ai/v1',
      LlmProvider.openrouter => 'https://openrouter.ai/api/v1',
      LlmProvider.perplexity => 'https://api.perplexity.ai',
      LlmProvider.together => 'https://api.together.xyz/v1',
      LlmProvider.fireworks => 'https://api.fireworks.ai/inference/v1',
      LlmProvider.deepseek => 'https://api.deepseek.com',
      LlmProvider.kimi => 'https://api.moonshot.cn/v1',
      LlmProvider.qwen => 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      LlmProvider.doubao => 'https://ark.cn-beijing.volces.com/api/v3',
      LlmProvider.zhipu => 'https://open.bigmodel.cn/api/paas/v4',
      LlmProvider.yi => 'https://api.lingyiwanwu.com/v1',
      LlmProvider.stepfun => 'https://api.stepfun.com/v1',
      LlmProvider.minimax => 'https://api.minimaxi.com/v1',
      LlmProvider.custom => null,
    };
  }

  String get defaultModel {
    return switch (this) {
      LlmProvider.claude => 'claude-sonnet-4-5-20250929',
      LlmProvider.openai => 'gpt-4o',
      LlmProvider.gemini => 'gemini-2.0-flash',
      LlmProvider.mistral => 'mistral-large-latest',
      LlmProvider.groq => 'llama-3.3-70b-versatile',
      LlmProvider.xai => 'grok-3',
      LlmProvider.openrouter => 'openai/gpt-4o',
      LlmProvider.perplexity => 'sonar',
      LlmProvider.together => 'meta-llama/Llama-3.3-70B-Instruct-Turbo',
      LlmProvider.fireworks =>
        'accounts/fireworks/models/llama-v3p3-70b-instruct',
      LlmProvider.deepseek => 'deepseek-chat',
      LlmProvider.kimi => 'kimi-latest',
      LlmProvider.qwen => 'qwen-plus',
      LlmProvider.doubao => 'doubao-1-5-pro-32k',
      LlmProvider.zhipu => 'glm-4-plus',
      LlmProvider.yi => 'yi-large',
      LlmProvider.stepfun => 'step-2-16k',
      LlmProvider.minimax => 'abab6.5s-chat',
      LlmProvider.custom => '',
    };
  }

  String get apiKeyHint {
    return switch (this) {
      LlmProvider.claude => 'sk-ant-...',
      LlmProvider.openai ||
      LlmProvider.deepseek ||
      LlmProvider.kimi ||
      LlmProvider.mistral ||
      LlmProvider.groq ||
      LlmProvider.together ||
      LlmProvider.fireworks ||
      LlmProvider.yi ||
      LlmProvider.stepfun ||
      LlmProvider.perplexity =>
        'sk-...',
      LlmProvider.gemini => 'AIza...',
      LlmProvider.xai => 'xai-...',
      LlmProvider.openrouter => 'sk-or-...',
      LlmProvider.qwen => 'sk-... (DashScope)',
      LlmProvider.doubao => 'ARK API Key',
      LlmProvider.zhipu => '<API Key>.<Secret>',
      LlmProvider.minimax => 'eyJ... (JWT)',
      LlmProvider.custom => 'API key',
    };
  }

  String get docsUrl {
    return switch (this) {
      LlmProvider.claude => 'https://console.anthropic.com/',
      LlmProvider.openai => 'https://platform.openai.com/api-keys',
      LlmProvider.gemini => 'https://aistudio.google.com/apikey',
      LlmProvider.mistral => 'https://console.mistral.ai/',
      LlmProvider.groq => 'https://console.groq.com/keys',
      LlmProvider.xai => 'https://console.x.ai/',
      LlmProvider.openrouter => 'https://openrouter.ai/keys',
      LlmProvider.perplexity => 'https://www.perplexity.ai/settings/api',
      LlmProvider.together => 'https://api.together.ai/settings/api-keys',
      LlmProvider.fireworks => 'https://fireworks.ai/account/api-keys',
      LlmProvider.deepseek => 'https://platform.deepseek.com/',
      LlmProvider.kimi => 'https://platform.moonshot.cn/',
      LlmProvider.qwen => 'https://dashscope.console.aliyun.com/',
      LlmProvider.doubao => 'https://www.volcengine.com/product/ark',
      LlmProvider.zhipu => 'https://open.bigmodel.cn/',
      LlmProvider.yi => 'https://platform.lingyiwanwu.com/',
      LlmProvider.stepfun => 'https://platform.stepfun.com/',
      LlmProvider.minimax => 'https://platform.minimaxi.com/',
      LlmProvider.custom => '',
    };
  }
}

LlmProvider llmProviderFromName(
  String? name, {
  LlmProvider fallback = LlmProvider.claude,
}) {
  if (name == null) return fallback;
  final String normalized = name.trim().toLowerCase();
  for (final LlmProvider provider in LlmProvider.values) {
    if (provider.name == normalized) return provider;
  }
  // Some friendly aliases users might write in agent.md frontmatter.
  return switch (normalized) {
    'anthropic' => LlmProvider.claude,
    'gpt' || 'chatgpt' => LlmProvider.openai,
    'google' || 'google-ai' || 'googleai' => LlmProvider.gemini,
    'moonshot' => LlmProvider.kimi,
    'dashscope' || 'tongyi' || 'aliyun' => LlmProvider.qwen,
    'volces' || 'ark' || 'bytedance' => LlmProvider.doubao,
    'glm' || 'bigmodel' => LlmProvider.zhipu,
    'grok' => LlmProvider.xai,
    '01ai' || '01-ai' || 'lingyiwanwu' => LlmProvider.yi,
    'step' => LlmProvider.stepfun,
    _ => fallback,
  };
}
