import 'package:flutter/material.dart';

import '../../core/models/card_model.dart';

/// Renders a single Card Mode suggestion. Sized by its parent (the deck gives
/// it a fixed box), so the layout uses a [Spacer] to push the confidence bar to
/// the bottom.
class CardWidget extends StatelessWidget {
  const CardWidget({required this.card, super.key});

  final CardModel card;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color confidenceColor = card.confidence > 0.8
        ? const Color(0xFF10B981)
        : card.confidence >= 0.6
            ? const Color(0xFFF59E0B)
            : colors.outline;

    return Material(
      color: Theme.of(context).cardColor,
      elevation: 4,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                _AgentBadge(agentKey: card.agentKey),
                const Spacer(),
                if (card.isFromChat)
                  Text(
                    'From chat',
                    style: TextStyle(color: colors.outline, fontSize: 11),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              card.title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            if (card.reason.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                card.reason,
                style: TextStyle(
                  color: colors.outline,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
            const Spacer(),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: card.confidence.clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: colors.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(confidenceColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentBadge extends StatelessWidget {
  const _AgentBadge({required this.agentKey});

  final String agentKey;

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (agentKey) {
      'codex' => ('Codex', const Color(0xFF10A37F)),
      'agy' => ('Antigravity', const Color(0xFF8B5CF6)),
      _ => ('Claude Code', const Color(0xFF3B82F6)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
