import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/util/time_format.dart';
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

class _QuotaUsageScreenState extends State<QuotaUsageScreen> {
  late Future<UsageReport> _usageFuture;

  @override
  void initState() {
    super.initState();
    _usageFuture = widget.chatController.usageReport();
  }

  void _refresh() {
    setState(() {
      _usageFuture = widget.chatController.usageReport();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.usageQuery),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: context.l10n.refresh,
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<UsageReport>(
          future: _usageFuture,
          builder: (
            BuildContext context,
            AsyncSnapshot<UsageReport> snapshot,
          ) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(context.l10n.loadingUsage),
                  ],
                ),
              );
            }
            if (snapshot.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    snapshot.error.toString(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              );
            }
            final UsageReport report = snapshot.data!;
            return RefreshIndicator(
              onRefresh: () async {
                _refresh();
                await _usageFuture;
              },
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: report.agents.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (BuildContext context, int index) {
                  return Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: _UsageAgentPanel(agent: report.agents[index]),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _UsageAgentPanel extends StatelessWidget {
  const _UsageAgentPanel({required this.agent});

  final UsageAgent agent;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  agent.label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
              if (agent.detail.isNotEmpty)
                Text(
                  agent.detail,
                  style: TextStyle(color: colors.outline, fontSize: 12),
                ),
            ],
          ),
          if (agent.asOf != null || agent.stale) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                if (agent.asOf != null)
                  Text(
                    context.l10n.usageAsOf(
                      formatShortTime(context, agent.asOf),
                    ),
                    style: TextStyle(color: colors.outline, fontSize: 12),
                  ),
                if (agent.stale)
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
          ],
          const SizedBox(height: 12),
          if (!agent.available)
            Text(
              context.l10n.unavailable,
              style: TextStyle(color: colors.outline),
            )
          else if (agent.error != null)
            Text(
              agent.error!,
              style: TextStyle(color: colors.error),
            )
          else if (agent.quotas.isEmpty)
            Text(
              context.l10n.unknown,
              style: TextStyle(color: colors.outline),
            )
          else
            for (final UsageQuota quota in agent.quotas)
              _UsageQuotaRow(quota: quota),
        ],
      ),
    );
  }
}

class _UsageQuotaRow extends StatelessWidget {
  const _UsageQuotaRow({required this.quota});

  final UsageQuota quota;

  String _formatPercent(BuildContext context, double? percent) {
    if (percent == null) return context.l10n.unknown;
    final double clamped = percent.clamp(0, 100).toDouble();
    if ((clamped - clamped.round()).abs() < 0.05) {
      return '${clamped.round()}%';
    }
    return '${clamped.toStringAsFixed(1)}%';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String label = switch (quota.key) {
      'five_hour' => context.l10n.fiveHourQuota,
      'seven_day' => context.l10n.weeklyQuota,
      _ => quota.label,
    };
    final double? percent = quota.remainingPercent;
    final String percentText = _formatPercent(context, percent);
    final double? value =
        percent == null ? null : (percent / 100).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 84,
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('$percentText ${context.l10n.remaining}'),
                    const SizedBox(height: 3),
                    Text(
                      '${context.l10n.refreshAt}: ${formatShortTime(context, quota.resetsAt)}',
                      style: TextStyle(color: colors.outline, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: value,
            minHeight: 6,
            borderRadius: BorderRadius.circular(999),
          ),
        ],
      ),
    );
  }
}
