import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/app_theme.dart';
import 'quota_controller.dart';

/// The agents whose quota the backend reports.
bool quotaStripSupports(String agentKey) =>
    agentKey == 'claude' || agentKey == 'codex';

/// The active agent's remaining quota, pinned above the composer. Display
/// only: the full quota screen opens from the agents drawer.
///
/// Numbers come from the controller's shared usage report. It refreshes when
/// the agent changes and when a turn ends (the turn just spent quota), at most
/// once a minute per agent; the backend caches for a minute as well, so these
/// reads are cheap.
class QuotaStrip extends StatefulWidget {
  const QuotaStrip({
    required this.quotaController,
    required this.agentKey,
    required this.busy,
    super.key,
  });

  final QuotaController quotaController;
  final String agentKey;

  /// Whether a turn is running; its end triggers a refresh.
  final bool busy;

  @override
  State<QuotaStrip> createState() => _QuotaStripState();
}

class _QuotaStripState extends State<QuotaStrip> {
  static const Duration _minInterval = Duration(minutes: 1);

  final Map<String, DateTime> _fetchedAt = <String, DateTime>{};
  // Until the first report arrives a spinner holds the strip's place, so the
  // line above the composer does not pop in late.
  bool _loading = false;
  // Re-renders the countdowns, and refetches once a shown window has reset.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _tick = Timer.periodic(_minInterval, (_) {
      if (!mounted) return;
      setState(() {});
      if (_windowPassed()) unawaited(_refresh());
    });
  }

  @override
  void didUpdateWidget(QuotaStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentKey != widget.agentKey ||
        (oldWidget.busy && !widget.busy)) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  UsageAgent? get _usage {
    for (final UsageAgent agent
        in widget.quotaController.lastUsageReport?.agents ??
            const <UsageAgent>[]) {
      if (agent.key == widget.agentKey) return agent;
    }
    return null;
  }

  bool _windowPassed() {
    final DateTime now = DateTime.now();
    return _usage?.quotas.any((UsageQuota quota) {
          final DateTime? reset = DateTime.tryParse(quota.resetsAt ?? '');
          return !quota.expired && reset != null && reset.isBefore(now);
        }) ??
        false;
  }

  Future<void> _refresh() async {
    final String source = widget.agentKey;
    if (!quotaStripSupports(source)) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _fetchedAt[source];
    if (last != null && now.difference(last) < _minInterval) return;
    _fetchedAt[source] = now;
    _loading = true;
    try {
      await widget.quotaController.usageReport(source: source);
    } catch (_) {
      // The strip keeps the last numbers; the quota screen reports errors.
    }
    _loading = false;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final UsageAgent? usage = _usage;
    if (!quotaStripSupports(widget.agentKey)) return const SizedBox.shrink();
    if (usage == null && _loading) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
      );
    }
    if (usage == null ||
        !usage.available ||
        usage.error != null ||
        usage.quotas.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Opacity(
        // A cached report from a failed refresh: still useful, but faded.
        opacity: usage.stale ? 0.6 : 1,
        child: Wrap(
          spacing: 18,
          runSpacing: 4,
          children: <Widget>[
            for (final UsageQuota quota in usage.quotas)
              _QuotaMeter(quota: quota),
          ],
        ),
      ),
    );
  }
}

class _QuotaMeter extends StatelessWidget {
  const _QuotaMeter({required this.quota});

  final UsageQuota quota;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final AppStrings strings = context.l10n;
    final String label = switch (quota.key) {
      'five_hour' => strings.fiveHourQuotaShort,
      'seven_day' => strings.weeklyQuotaShort,
      _ => quota.label,
    };
    final TextStyle labelStyle = TextStyle(fontSize: 12, color: colors.outline);
    // An expired bucket's cached number is meaningless; say it reset instead.
    final double? percent =
        quota.expired ? null : quota.remainingPercent?.clamp(0, 100).toDouble();
    if (percent == null) {
      return Text(
        '$label  ${quota.expired ? strings.quotaResetShort : strings.unknown}',
        style: labelStyle,
      );
    }
    final Color tone = quotaTone(colors, percent);
    final DateTime? reset = DateTime.tryParse(quota.resetsAt ?? '');
    final Duration? left = reset?.difference(DateTime.now());
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: labelStyle),
        const SizedBox(width: 6),
        SizedBox(
          width: 36,
          child: LinearProgressIndicator(
            value: percent / 100,
            minHeight: 4,
            color: tone,
            backgroundColor: tone.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '${percent.round()}%',
          style: AppTheme.mono(colors.onSurface).copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (left != null && !left.isNegative) ...<Widget>[
          const SizedBox(width: 6),
          // Not monospace: the units can be CJK, which the mono font lacks.
          Text(
            strings.resetsInShort(left),
            style: TextStyle(
              fontSize: 11,
              color: colors.outline,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}
