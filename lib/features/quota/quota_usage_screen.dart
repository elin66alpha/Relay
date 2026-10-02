import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/time_format.dart';
import '../../core/widgets/agent_icon.dart';
import '../chat/bot_chat_controller.dart';

class QuotaUsageScreen extends StatefulWidget {
  const QuotaUsageScreen({
    required this.chatController,
    super.key,
  });

  final BotChatController chatController;

  @override
  State<QuotaUsageScreen> createState() => _QuotaUsageScreenState();
}

// The quota sources the backend reports, in display order, with the label shown
// until each one's first report arrives.
const Map<String, String> _usageSources = <String, String>{
  'claude': 'Claude Code',
  'codex': 'Codex',
};

class _QuotaUsageScreenState extends State<QuotaUsageScreen> {
  // Seeded from the last report the app fetched, so reopening the screen shows
  // the previous numbers at once. Each source is then refreshed on its own and
  // lands as soon as it answers: Codex's probe can take seconds, Claude's not.
  UsageReport? _report;
  final Map<String, String> _errors = <String, String>{};
  bool _loading = false;
  // Keeps the "resets in" countdowns current.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _report = widget.chatController.lastUsageReport;
    unawaited(_refresh());
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _errors.clear();
    });
    await Future.wait(_usageSources.keys.map(_refreshSource));
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshSource(String source) async {
    try {
      final UsageReport report =
          await widget.chatController.usageReport(source: source);
      if (!mounted) return;
      setState(() => _report = report);
    } catch (err) {
      if (!mounted) return;
      setState(() => _errors[source] = err.toString());
      // With numbers already on screen the failure would otherwise be silent.
      if (_agent(source) != null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(err.toString())));
      }
    }
  }

  UsageAgent? _agent(String source) {
    for (final UsageAgent agent in _report?.agents ?? const <UsageAgent>[]) {
      if (agent.key == source) return agent;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.usageQuery),
        bottom: _loading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: context.l10n.refresh,
            onPressed: _loading ? null : () => unawaited(_refresh()),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final List<String> sources = _usageSources.keys.toList(growable: false);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: sources.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (BuildContext context, int index) {
          final String source = sources[index];
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: _UsageAgentPanel(
                source: source,
                label: _usageSources[source]!,
                agent: _agent(source),
                error: _errors[source],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The colour of a quota with [remainingPercent] left: the accent while there
/// is room, amber when it runs low, red when nearly gone.
Color quotaTone(ColorScheme colors, double remainingPercent) {
  if (remainingPercent < 10) return colors.error;
  if (remainingPercent < 25) return AppTheme.statusWarn;
  return colors.primary;
}

class _UsageAgentPanel extends StatelessWidget {
  const _UsageAgentPanel({
    required this.source,
    required this.label,
    this.agent,
    this.error,
  });

  final String source;
  final String label;
  // Null until the source's first report arrives.
  final UsageAgent? agent;
  // Only drawn while [agent] is null; with numbers on screen a failed refresh
  // is reported by a snackbar instead.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final UsageAgent? agent = this.agent;
    final TextStyle muted = TextStyle(color: colors.outline, fontSize: 12);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                AgentIcon(agentKey: source, size: 22),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    agent?.label ?? label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                // The plan, e.g. "pro" or "plus".
                if (agent != null && agent.detail.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      agent.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.mono(colors.onSurfaceVariant)
                          .copyWith(fontSize: 11, height: 1.4),
                    ),
                  ),
                ],
                const Spacer(),
                if (agent != null && agent.stale)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: colors.tertiaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      context.l10n.usageStale,
                      style: TextStyle(
                        color: colors.onTertiaryContainer,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            if (agent?.asOf != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                context.l10n.usageAsOf(formatShortTime(context, agent!.asOf)),
                style: muted,
              ),
            ],
            const SizedBox(height: 14),
            if (agent == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  error ?? context.l10n.loadingUsage,
                  style: TextStyle(
                    color: error == null ? colors.outline : colors.error,
                  ),
                ),
              )
            else if (!agent.available)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  context.l10n.unavailable,
                  style: TextStyle(color: colors.outline),
                ),
              )
            else if (agent.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  agent.error!,
                  style: TextStyle(color: colors.error),
                ),
              )
            else if (agent.quotas.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  context.l10n.unknown,
                  style: TextStyle(color: colors.outline),
                ),
              )
            else
              for (final UsageQuota quota in agent.quotas)
                _UsageQuotaRow(quota: quota),
          ],
        ),
      ),
    );
  }
}

class _UsageQuotaRow extends StatelessWidget {
  const _UsageQuotaRow({required this.quota});

  final UsageQuota quota;

  String _formatPercent(double percent) {
    if ((percent - percent.round()).abs() < 0.05) return '${percent.round()}%';
    return '${percent.toStringAsFixed(1)}%';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final AppStrings strings = context.l10n;
    final String label = switch (quota.key) {
      'five_hour' => strings.fiveHourQuota,
      'seven_day' => strings.weeklyQuota,
      _ => quota.label,
    };
    // An expired bucket's cached percentage is meaningless (its window already
    // reset while the source was unreachable), so drop the number and let the
    // bar fall to its indeterminate "awaiting fresh data" state.
    final double? percent = quota.expired
        ? null
        : quota.remainingPercent?.clamp(0, 100).toDouble();
    final Color tone =
        percent == null ? colors.outline : quotaTone(colors, percent);
    final DateTime? reset = DateTime.tryParse(quota.resetsAt ?? '');
    final Duration? left = reset?.difference(DateTime.now());
    final TextStyle muted = TextStyle(color: colors.outline, fontSize: 12);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (quota.expired)
                Text(
                  strings.quotaWindowReset,
                  style: TextStyle(color: colors.tertiary, fontSize: 13),
                )
              else
                Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(
                        text: percent == null
                            ? strings.unknown
                            : _formatPercent(percent),
                        style: AppTheme.mono(tone).copyWith(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      TextSpan(text: ' ${strings.remaining}', style: muted),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: percent == null ? null : percent / 100,
            minHeight: 6,
            color: tone,
            backgroundColor: tone.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(999),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              if (left != null && !left.isNegative)
                Text(
                  strings.resetsIn(left),
                  style: muted.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              const Spacer(),
              Text(
                '${strings.refreshAt}: '
                '${formatShortTime(context, quota.resetsAt)}',
                style: muted,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
