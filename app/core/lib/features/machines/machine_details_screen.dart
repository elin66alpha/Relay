import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/machine_credential.dart';
import '../../core/util/format_bytes.dart';
import '../../core/util/time_format.dart';
import '../cli_agents/agent_status_lights.dart';
import '../cli_agents/cli_agents_controller.dart';
import '../ssh/ssh_terminal_controller.dart';
import '../ssh/ssh_terminal_screen.dart';

/// One machine on a single page: the SSH terminal entry, its hardware and live
/// temperatures, CLI agent status, the device tokens issued by its backend,
/// then the backend's status report.
class MachineDetailsScreen extends StatefulWidget {
  const MachineDetailsScreen({
    required this.machine,
    required this.backend,
    required this.agentsController,
    super.key,
  });

  final MachineCredential machine;
  final BackendClient backend;
  final CliAgentsController agentsController;

  @override
  State<MachineDetailsScreen> createState() => _MachineDetailsScreenState();
}

class _MachineDetailsScreenState extends State<MachineDetailsScreen> {
  // Owned by the page, so leaving and re-entering SSH reuses one terminal.
  late final SshTerminalController _sshController = SshTerminalController(
    backend: widget.backend,
  );
  Future<String>? _status;

  @override
  void dispose() {
    _sshController.dispose();
    super.dispose();
  }

  void _enterSsh() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SshTerminalScreen(
          controller: _sshController,
          machineId: widget.machine.id,
        ),
      ),
    );
  }

  Future<String> _loadStatus(
    AppStrings strings, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final BackendDiagnostics diagnostics = await widget.backend.diagnostics(
        timeout: timeout,
      );
      return diagnostics.toDisplayText(strings);
    } on BackendException catch (err) {
      if (err.status != 404) rethrow;
      final BackendStatus status = await widget.backend.status(
        timeout: timeout,
      );
      return status.toDisplayText(strings);
    }
  }

  Future<void> _refreshAgents() async {
    try {
      final List<CliAgent> agents = await widget.backend
          .fetchAgents(verifyCredentials: true);
      if (!mounted) return;
      widget.agentsController.syncAgents(agents);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.agentStatusRefreshFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final ColorScheme colors = Theme.of(context).colorScheme;
    _status ??= _loadStatus(strings);
    return Scaffold(
      appBar: AppBar(title: Text(strings.machineDetails)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: _enterSsh,
                        icon: const Icon(Icons.terminal_rounded),
                        label: Text(strings.enterSsh),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _MachineInfoPanel(
                      backend: widget.backend,
                      title: widget.machine.displayName,
                    ),
                    const SizedBox(height: 20),
                    _AgentCredentialStatusSection(
                      agentsController: widget.agentsController,
                      onRefresh: _refreshAgents,
                    ),
                    const SizedBox(height: 20),
                    _DeviceTokensPanel(backend: widget.backend),
                    const SizedBox(height: 20),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            strings.status,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded),
                          tooltip: strings.refresh,
                          onPressed: () => setState(() {
                            _status = _loadStatus(strings);
                          }),
                        ),
                      ],
                    ),
                    FutureBuilder<String>(
                      future: _status,
                      builder: (
                        BuildContext context,
                        AsyncSnapshot<String> snap,
                      ) {
                        if (snap.connectionState != ConnectionState.done) {
                          return const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }
                        return SelectableText(
                          snap.hasError
                              ? strings.statusLoadFailed(snap.error!)
                              : snap.data ?? strings.noStatus,
                          style: TextStyle(
                            color: snap.hasError ? colors.error : null,
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MachineInfoPanel extends StatefulWidget {
  const _MachineInfoPanel({required this.backend, required this.title});

  final BackendClient backend;
  final String title;

  @override
  State<_MachineInfoPanel> createState() => _MachineInfoPanelState();
}

class _MachineInfoPanelState extends State<_MachineInfoPanel> {
  Timer? _timer;
  MachineInfo? _info;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // Temperatures change slowly; one sample every 10 seconds is enough.
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final MachineInfo info = await widget.backend.machineInfo();
      if (!mounted) return;
      setState(() {
        _info = info;
        _error = null;
      });
    } catch (err) {
      // A backend older than /api/machine never will answer; stop asking.
      if (err is BackendException && err.status == 404) _timer?.cancel();
      if (!mounted) return;
      setState(() => _error = err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final MachineInfo? info = _info;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            if (info == null && _error == null)
              const Center(child: CircularProgressIndicator())
            else if (info == null)
              Text(
                strings.statusLoadFailed(_error!),
                style: TextStyle(color: colors.error),
              )
            else ...<Widget>[
              _HardwareRow(
                icon: Icons.memory_rounded,
                label: strings.cpuLabel,
                value: info.cpuThreads > 0
                    ? '${info.cpuModel} · ${strings.cpuThreads(info.cpuThreads)}'
                    : info.cpuModel,
              ),
              _HardwareRow(
                icon: Icons.developer_board_rounded,
                label: strings.memoryLabel,
                value: formatBytes(info.memoryBytes),
              ),
              for (final String gpu in info.gpus)
                _HardwareRow(
                  icon: Icons.videogame_asset_rounded,
                  label: strings.gpuLabel,
                  value: gpu,
                ),
              for (final StorageDisk disk in info.disks)
                _HardwareRow(
                  icon: Icons.storage_rounded,
                  label: strings.storageLabel,
                  value: strings.storageUsage(
                    disk.mount,
                    formatBytes(disk.usedBytes),
                    formatBytes(disk.totalBytes),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                strings.temperatures,
                style: TextStyle(
                  color: colors.outline,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              if (info.temperatures.isEmpty)
                Text(
                  strings.noTemperatureSensors,
                  style: TextStyle(color: colors.outline),
                )
              else
                Row(
                  children: <Widget>[
                    for (final TemperatureReading reading in info.temperatures)
                      Expanded(child: _TemperatureTile(reading: reading)),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HardwareRow extends StatelessWidget {
  const _HardwareRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: colors.primary),
          const SizedBox(width: 10),
          SizedBox(
            width: 64,
            // Shrink rather than break a word when text scaling is large.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(label, style: TextStyle(color: colors.outline)),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _TemperatureTile extends StatelessWidget {
  const _TemperatureTile({required this.reading});

  final TemperatureReading reading;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool hot = reading.celsius >= 80;
    final String label = switch (reading.key) {
      'mainboard' => context.l10n.mainboardLabel,
      'ssd' => 'SSD',
      'cpu' => 'CPU',
      'gpu' => 'GPU',
      _ => reading.label,
    };
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: hot ? colors.errorContainer : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: <Widget>[
          // Four tiles share a phone's width: shrink, never wrap mid-word.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: hot ? colors.onErrorContainer : colors.outline,
              ),
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '${reading.celsius.round()}°C',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: hot ? colors.onErrorContainer : colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentCredentialStatusSection extends StatelessWidget {
  const _AgentCredentialStatusSection({
    required this.agentsController,
    required this.onRefresh,
  });

  final CliAgentsController agentsController;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AnimatedBuilder(
      animation: agentsController,
      builder: (BuildContext context, Widget? _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      context.l10n.cliAgents,
                      style: TextStyle(
                        color: theme.colorScheme.outline,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.recheck,
                    onPressed: () => unawaited(onRefresh()),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  for (int index = 0;
                      index < agentsController.agents.length;
                      index += 1)
                    _AgentCredentialStatusTile(
                      agent: agentsController.agents[index],
                      showDivider: index > 0,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AgentCredentialStatusTile extends StatelessWidget {
  const _AgentCredentialStatusTile({
    required this.agent,
    required this.showDivider,
  });

  final CliAgent agent;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppStrings strings = context.l10n;
    final bool usable = isCliAgentSelectable(agent);
    final Color? textColor = usable ? null : theme.colorScheme.onSurfaceVariant;
    final String? subtitle = usable
        ? _readySubtitle(strings, agent)
        : agentUnavailableMessage(strings, agent);
    return Column(
      children: <Widget>[
        if (showDivider) const Divider(height: 1),
        ListTile(
          dense: true,
          title: Text(agent.label, style: TextStyle(color: textColor)),
          subtitle: subtitle == null
              ? null
              : Text(
                  subtitle,
                  style: TextStyle(
                    color: theme.colorScheme.outline,
                  ),
                ),
          trailing: Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              AgentStatusLights(agent: agent),
              _AgentCredentialAction(agent: agent),
            ],
          ),
        ),
      ],
    );
  }

  String? _readySubtitle(AppStrings strings, CliAgent agent) {
    if (agent.key == 'opencode') return strings.optionalApiKey;
    if (agent.authKind == 'apiKey') return strings.agentReady;
    if (agent.authKind == 'oauth') return strings.agentReady;
    return null;
  }
}

// Small enough that the agent name beside it keeps its words on one line in
// portrait.
final ButtonStyle _compactButton = OutlinedButton.styleFrom(
  visualDensity: VisualDensity.compact,
  padding: const EdgeInsets.symmetric(horizontal: 10),
  textStyle: const TextStyle(fontSize: 12),
);

class _AgentCredentialAction extends StatelessWidget {
  const _AgentCredentialAction({required this.agent});

  final CliAgent agent;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    if (!agent.installed) {
      return OutlinedButton(
        onPressed: null,
        style: _compactButton,
        child: Text(strings.unavailable),
      );
    }
    // Every agent's credential is created on the backend host: claude/codex with
    // their own `login` command, hermes/opencode with a provider key. Relay only
    // reports the state it can read there.
    if (agent.key == 'opencode' || agent.key == 'hermes') {
      return OutlinedButton(
        onPressed: null,
        style: _compactButton,
        child: Text(strings.keyManagedOnHost),
      );
    }
    return const SizedBox.shrink();
  }
}

class _DeviceTokensPanel extends StatefulWidget {
  const _DeviceTokensPanel({required this.backend});

  final BackendClient backend;

  @override
  State<_DeviceTokensPanel> createState() => _DeviceTokensPanelState();
}

class _DeviceTokensPanelState extends State<_DeviceTokensPanel> {
  late Future<List<DeviceToken>> _tokensFuture;
  List<DeviceToken> _tokens = const <DeviceToken>[];
  final Set<String> _revoking = <String>{};
  final Set<String> _deleting = <String>{};

  @override
  void initState() {
    super.initState();
    _tokensFuture = _loadTokens();
  }

  Future<List<DeviceToken>> _loadTokens() async {
    final List<DeviceToken> tokens = await widget.backend.deviceTokens();
    _tokens = tokens;
    return tokens;
  }

  void _refresh() {
    setState(() {
      _tokensFuture = _loadTokens();
    });
  }

  Future<bool> _confirmCurrentRevoke(DeviceToken token) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.l10n.revokeCurrentTokenTitle),
        content: Text(context.l10n.revokeCurrentTokenBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.revokeToken),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _revoke(DeviceToken token) async {
    if (token.current && !await _confirmCurrentRevoke(token)) return;
    if (!mounted) return;
    setState(() {
      _revoking.add(token.id);
    });
    try {
      await widget.backend.revokeDeviceToken(token.id);
      if (!mounted) return;
      final String now = DateTime.now().toUtc().toIso8601String();
      final List<DeviceToken> next = _tokens
          .map(
            (DeviceToken item) => item.id == token.id
                ? item.copyWith(revoked: true, revokedAt: now)
                : item,
          )
          .toList(growable: false);
      setState(() {
        _tokens = next;
        _tokensFuture = Future<List<DeviceToken>>.value(next);
      });
      final String label = token.label.isEmpty ? token.id : token.label;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.tokenRevoked(label))));
      if (!token.current) _refresh();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.tokenRevokeFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _revoking.remove(token.id);
        });
      }
    }
  }

  Future<void> _delete(DeviceToken token) async {
    if (!token.revoked || _deleting.contains(token.id)) return;
    setState(() {
      _deleting.add(token.id);
    });
    try {
      await widget.backend.deleteDeviceToken(token.id);
      if (!mounted) return;
      final List<DeviceToken> next = _tokens
          .where((DeviceToken item) => item.id != token.id)
          .toList(growable: false);
      setState(() {
        _tokens = next;
        _tokensFuture = Future<List<DeviceToken>>.value(next);
      });
      final String label = token.label.isEmpty ? token.id : token.label;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.tokenDeleted(label))));
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.tokenDeleteFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _deleting.remove(token.id);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<DeviceToken>>(
      future: _tokensFuture,
      builder: (BuildContext context, AsyncSnapshot<List<DeviceToken>> snap) {
        final ColorScheme colors = Theme.of(context).colorScheme;
        final List<DeviceToken> tokens = snap.data ?? _tokens;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    context.l10n.deviceTokens,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: context.l10n.refresh,
                  onPressed: snap.connectionState == ConnectionState.waiting
                      ? null
                      : _refresh,
                ),
              ],
            ),
            if (snap.connectionState == ConnectionState.waiting &&
                tokens.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (snap.hasError && tokens.isEmpty)
              Text(snap.error.toString(), style: TextStyle(color: colors.error))
            else if (tokens.isEmpty)
              Text(
                context.l10n.noDeviceTokens,
                style: TextStyle(color: colors.outline),
              )
            else
              for (final DeviceToken token in tokens)
                _DeviceTokenRow(
                  token: token,
                  busy:
                      _revoking.contains(token.id) ||
                      _deleting.contains(token.id),
                  onRevoke: () => _revoke(token),
                  onDelete: () => _delete(token),
                ),
          ],
        );
      },
    );
  }
}

class _DeviceTokenRow extends StatelessWidget {
  const _DeviceTokenRow({
    required this.token,
    required this.busy,
    required this.onRevoke,
    required this.onDelete,
  });

  final DeviceToken token;
  final bool busy;
  final VoidCallback onRevoke;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String deviceInfo = _tokenDeviceInfo(token);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                token.current
                    ? Icons.phone_android_rounded
                    : Icons.devices_other_rounded,
                color: token.revoked ? colors.outline : colors.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          token.label.isEmpty ? token.id : token.label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        if (token.current)
                          _TokenBadge(
                            label: context.l10n.currentDeviceToken,
                            color: colors.primaryContainer,
                            textColor: colors.onPrimaryContainer,
                          ),
                        if (token.revoked)
                          _TokenBadge(
                            label: context.l10n.revokedDeviceToken,
                            color: colors.errorContainer,
                            textColor: colors.onErrorContainer,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.tokenCreatedAt(
                        formatShortTime(context, token.createdAt),
                      ),
                      style: TextStyle(color: colors.outline, fontSize: 12),
                    ),
                    if (token.revokedAt != null)
                      Text(
                        context.l10n.tokenRevokedAt(
                          formatShortTime(context, token.revokedAt),
                        ),
                        style: TextStyle(color: colors.outline, fontSize: 12),
                      ),
                    if (!token.revoked && deviceInfo.isNotEmpty)
                      Text(
                        context.l10n.tokenUsedBy(deviceInfo),
                        style: TextStyle(color: colors.outline, fontSize: 12),
                      ),
                    if (!token.revoked && token.lastUsedAt != null)
                      Text(
                        context.l10n.tokenLastUsedAt(
                          formatShortTime(context, token.lastUsedAt),
                        ),
                        style: TextStyle(color: colors.outline, fontSize: 12),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton(
                  onPressed: token.revoked ? onDelete : onRevoke,
                  child: Text(
                    token.revoked
                        ? context.l10n.deleteToken
                        : context.l10n.revokeToken,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _tokenDeviceInfo(DeviceToken token) {
  final String deviceId = token.lastDeviceId;
  final String shortId = deviceId.length <= 8
      ? deviceId
      : '${deviceId.substring(0, 8)}...';
  if (token.lastDeviceName.isNotEmpty && shortId.isNotEmpty) {
    return '${token.lastDeviceName} ($shortId)';
  }
  return token.lastDeviceName.isNotEmpty ? token.lastDeviceName : shortId;
}

class _TokenBadge extends StatelessWidget {
  const _TokenBadge({
    required this.label,
    required this.color,
    required this.textColor,
  });

  final String label;
  final Color color;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
