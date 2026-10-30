import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/models/chat_message.dart';
import '../../core/theme/app_theme.dart';

/// Cursor's ACP server reports no context usage, so its meter would only ever
/// read `? / ?`.
bool contextMeterSupports(String agentKey) => agentKey != 'cursor';

/// The context size reported after the conversation's latest reply that has
/// one. A reply still streaming has none yet, so the previous size stands.
({int used, int size})? latestContextUsage(List<ChatMessage> messages) {
  for (final ChatMessage message in messages.reversed) {
    final ({int used, int size})? usage = message.contextUsage;
    if (usage != null) return usage;
  }
  return null;
}

({int? used, int? size}) contextMeterUsage(
  List<ChatMessage> messages, {
  int? contextWindow,
}) {
  final ({int used, int size})? latest = latestContextUsage(messages);
  if (latest != null) return latest;
  final bool hasReply = messages.any(
    (ChatMessage message) =>
        message.role == ChatRole.assistant &&
        message.metadata['streaming'] != true,
  );
  return (used: hasReply ? null : 0, size: contextWindow);
}

/// `11377` -> `11k`, `1000000` -> `1M`, `1500000` -> `1.5M`.
String formatTokenCount(int tokens) {
  if (tokens >= 1000000) {
    final String millions = (tokens / 1000000).toStringAsFixed(1);
    return '${millions.endsWith('.0') ? millions.substring(0, millions.length - 2) : millions}M';
  }
  if (tokens >= 1000) return '${(tokens / 1000).round()}k';
  return '$tokens';
}

/// What the conversation occupies of the model's context window, shown at the
/// right end of the line above the composer.
class ContextMeter extends StatelessWidget {
  const ContextMeter({required this.usage, super.key});

  final ({int? used, int? size}) usage;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int? used = usage.used;
    final int? size = usage.size;
    final double? remaining =
        used != null && size != null ? 100 - used * 100 / size : null;
    return Padding(
      // Matches QuotaStrip's padding so both sit on one baseline.
      padding: const EdgeInsets.only(bottom: 8),
      child: Tooltip(
        message: context.l10n.contextUsage,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            '${used == null ? '?' : formatTokenCount(used)} / ${size == null ? '?' : formatTokenCount(size)}',
            style: AppTheme.mono(
              remaining != null && remaining < 25
                  ? quotaTone(colors, remaining)
                  : colors.outline,
            ).copyWith(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}
