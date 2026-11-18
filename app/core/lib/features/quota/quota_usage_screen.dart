import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/cli_agent.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/time_format.dart';
import '../../core/widgets/agent_icon.dart';
import 'quota_controller.dart';

class QuotaUsageScreen extends StatefulWidget {
  const QuotaUsageScreen({
    required this.quotaController,
    required this.ensureActiveSessionId,
    super.key,
  });

  final QuotaController quotaController;
  final Future<String> Function(CliAgent) ensureActiveSessionId;

  @override
  State<QuotaUsageScreen> createState() => _QuotaUsageScreenState();
}

// The quota sources the backend reports, in display order, with the label shown
// until each one's first report arrives.
const Map<String, String> _usageSources = <String, String>{
  'claude': 'Claude Code',
  'codex': 'Codex',
  'cursor': 'Cursor',
  'agy': 'Antigravity',
};

class _QuotaUsageScreenState extends State<QuotaUsageScreen> {
  // Seeded from the last report the app fetched, so reopening the screen shows
  // the previous numbers at once. Each source is then refreshed on its own and
  // lands as soon as it answers: Codex's probe can take seconds, Claude's not.
  UsageReport? _report;
  List<QuotaSchedule> _schedules = const <QuotaSchedule>[];
  final Map<String, String> _errors = <String, String>{};
  final Set<String> _savingAgents = <String>{};
  bool _loading = false;
  late int _seenScheduleRevision;
  // Keeps the "resets in" countdowns current.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _seenScheduleRevision = widget.quotaController.quotaScheduleRevision;
    _report = widget.quotaController.lastUsageReport;
    widget.quotaController.addListener(_onControllerChanged);
    unawaited(_refresh());
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.quotaController.removeListener(_onControllerChanged);
    _tick?.cancel();
    super.dispose();
  }

  void _onControllerChanged() {
    final int revision = widget.quotaController.quotaScheduleRevision;
    if (revision == _seenScheduleRevision) return;
    _seenScheduleRevision = revision;
    // A schedule event (created/sent/failed/cancelled — here or on another
    // device in this workspace) only changes the schedule list, never the usage
    // percentages, so refetch just the schedules and skip the costly usage call.
    unawaited(_reloadSchedules());
  }

  Future<void> _reloadSchedules() async {
    try {
      final List<QuotaSchedule> schedules =
          await widget.quotaController.quotaSchedules();
      if (!mounted) return;
      setState(() => _schedules = schedules);
    } catch (_) {
      // Keep the last snapshot; manual refresh or the next event recovers.
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _errors.clear();
    });
    await Future.wait(<Future<void>>[
      ..._usageSources.keys.map(_refreshSource),
      _reloadSchedules(),
    ]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshSource(String source) async {
    try {
      final UsageReport report =
          await widget.quotaController.usageReport(source: source);
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

  QuotaSchedule? _activeScheduleFor(String sourceKey) {
    for (final QuotaSchedule schedule in _schedules) {
      if (schedule.sourceKey == sourceKey &&
          (schedule.status == 'pending' || schedule.status == 'running')) {
        return schedule;
      }
    }
    return null;
  }

  UsageQuota? _fiveHourQuota(UsageAgent? agent) {
    if (agent == null) return null;
    for (final UsageQuota quota in agent.quotas) {
      if (quota.key == 'five_hour') return quota;
    }
    return null;
  }

  bool _supportsSchedule(String source) =>
      source == 'claude' || source == 'codex';

  Future<void> _openScheduleDialog(BuildContext context, String source) async {
    final UsageAgent? agent = _agent(source);
    final String agentLabel = agent?.label ?? _usageSources[source]!;
    final UsageQuota? fiveHour = _fiveHourQuota(agent);
    final QuotaSchedule? schedule = _activeScheduleFor(source);
    final AppStrings strings = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String resetTime = formatShortTime(
      context,
      fiveHour?.resetsAt ?? schedule?.targetResetsAt,
    );
    void showSnack(String text) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    }

    String draftPrompt = schedule?.prompt ?? '';
    bool saving = false;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext dialogContext, StateSetter setDialogState) {
            Future<void> submit() async {
              final String prompt = draftPrompt.trim();
              if (prompt.isEmpty) {
                showSnack(strings.messageRequired);
                return;
              }
              setDialogState(() => saving = true);
              if (mounted) setState(() => _savingAgents.add(source));
              try {
                final CliAgent targetAgent = cliAgentByKey(source);
                final String sessionId =
                    await widget.ensureActiveSessionId(targetAgent);
                final QuotaSchedule created =
                    await widget.quotaController.createQuotaSchedule(
                  sourceKey: source,
                  agentKey: targetAgent.key,
                  sessionId: sessionId,
                  prompt: prompt,
                  targetResetsAt: fiveHour?.resetsAt,
                  replaceExisting: true,
                );
                if (mounted) {
                  setState(() {
                    _schedules = <QuotaSchedule>[
                      for (final QuotaSchedule existing in _schedules)
                        if (existing.sourceKey != source) existing,
                      created,
                    ];
                  });
                }
                await _reloadSchedules();
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                if (mounted) {
                  showSnack(strings.scheduleUpdated(agentLabel));
                }
              } catch (err) {
                if (dialogContext.mounted) setDialogState(() => saving = false);
                if (mounted) {
                  showSnack(strings.scheduleFailed(err));
                }
              } finally {
                if (mounted) setState(() => _savingAgents.remove(source));
              }
            }

            Future<void> clear() async {
              if (schedule == null) return;
              setDialogState(() => saving = true);
              if (mounted) setState(() => _savingAgents.add(source));
              try {
                await widget.quotaController.cancelQuotaSchedule(schedule.id);
                if (mounted) {
                  setState(() {
                    _schedules = _schedules
                        .where((QuotaSchedule item) => item.id != schedule.id)
                        .toList(growable: false);
                  });
                }
                await _reloadSchedules();
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                if (mounted) {
                  showSnack(strings.scheduleCleared(agentLabel));
                }
              } catch (err) {
                if (dialogContext.mounted) setDialogState(() => saving = false);
                if (mounted) {
                  showSnack(strings.scheduleFailed(err));
                }
              } finally {
                if (mounted) setState(() => _savingAgents.remove(source));
              }
            }

            return PopScope(
              canPop: !saving,
              child: AlertDialog(
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 24,
                ),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(strings.quotaScheduler),
                    const SizedBox(height: 2),
                    Text(
                      agentLabel,
                      style: Theme.of(dialogContext)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                            color: Theme.of(dialogContext).colorScheme.outline,
                          ),
                    ),
                  ],
                ),
                content: SizedBox(
                  // Clamped by the dialog on narrow screens.
                  width: 560,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        TextFormField(
                          initialValue: draftPrompt,
                          autofocus: true,
                          enabled: !saving,
                          minLines: 2,
                          maxLines: 5,
                          decoration:
                              InputDecoration(labelText: strings.prompt),
                          onChanged: (String value) => draftPrompt = value,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${strings.refreshAt}: $resetTime',
                          style: TextStyle(
                            color: Theme.of(dialogContext).colorScheme.outline,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed:
                        saving ? null : () => Navigator.of(dialogContext).pop(),
                    child: Text(strings.cancel),
                  ),
                  if (schedule != null)
                    TextButton(
                      onPressed: saving ? null : clear,
                      child: Text(strings.clearSchedule),
                    ),
                  FilledButton(
                    onPressed: saving ? null : submit,
                    child: saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(strings.send),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
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
          final UsageAgent? agent = _agent(source);
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: _UsageAgentPanel(
                source: source,
                label: _usageSources[source]!,
                agent: agent,
                error: _errors[source],
                supportsSchedule: _supportsSchedule(source),
                schedule: _supportsSchedule(source)
                    ? _activeScheduleFor(source)
                    : null,
                fiveHourReset: _fiveHourQuota(agent)?.resetsAt,
                saving: _savingAgents.contains(source),
                onScheduleTap: _supportsSchedule(source)
                    ? () => unawaited(_openScheduleDialog(context, source))
                    : null,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _UsageAgentPanel extends StatelessWidget {
  const _UsageAgentPanel({
    required this.source,
    required this.label,
    required this.supportsSchedule,
    required this.saving,
    this.agent,
    this.error,
    this.schedule,
    this.fiveHourReset,
    this.onScheduleTap,
  });

  final String source;
  final String label;
  final bool supportsSchedule;
  final bool saving;
  // Null until the source's first report arrives.
  final UsageAgent? agent;
  // Only drawn while [agent] is null; with numbers on screen a failed refresh
  // is reported by a snackbar instead.
  final String? error;
  final QuotaSchedule? schedule;
  final String? fiveHourReset;
  final VoidCallback? onScheduleTap;

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
                Expanded(
                  child: Row(
                    children: <Widget>[
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
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 1,
                          ),
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
                    ],
                  ),
                ),
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
                if (supportsSchedule) ...<Widget>[
                  if (agent != null && agent.stale) const SizedBox(width: 4),
                  TextButton.icon(
                    icon: Icon(
                      schedule != null
                          ? Icons.schedule_send_rounded
                          : Icons.schedule_send_outlined,
                      size: 18,
                    ),
                    label: Text(context.l10n.quotaScheduler),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: saving ? null : onScheduleTap,
                  ),
                ],
              ],
            ),
            if (agent?.asOf != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                context.l10n.usageAsOf(formatShortTime(context, agent!.asOf)),
                style: muted,
              ),
            ],
            if (schedule != null) ...<Widget>[
              const SizedBox(height: 8),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: saving ? null : onScheduleTap,
                child: SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          context.l10n.scheduledMessageAt(
                            formatShortTime(
                              context,
                              schedule!.targetResetsAt ?? fiveHourReset,
                            ),
                          ),
                          style: TextStyle(
                            color: colors.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          schedule!.prompt,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ],
                    ),
                  ),
                ),
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
    final String label = switch ((quota.window, quota.key)) {
      ('5h', _) => '${quota.label} ${strings.fiveHourQuota}',
      ('weekly', _) => '${quota.label} ${strings.weeklyQuota}',
      (_, 'five_hour') => strings.fiveHourQuota,
      (_, 'seven_day') => strings.weeklyQuota,
      (_, 'cursor_models') => strings.cursorModelsQuota,
      (_, 'api_models') => strings.apiModelsQuota,
      _ => quota.label,
    };
    // An expired bucket's cached percentage is meaningless (its window already
    // reset while the source was unreachable), so drop the number and let the
    // bar fall to its indeterminate "awaiting fresh data" state.
    final double? percent =
        quota.expired ? null : quota.remainingPercent?.clamp(0, 100).toDouble();
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
