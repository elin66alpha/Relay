import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/agent_options.dart';

/// Per-agent Model / Effort / Permission controls shown in the chat composer's
/// "+" drawer. Capability-aware: only groups the agent supports are rendered
/// for the current workdir+agent scope, so every device in that scope shares
/// them.

const List<String> _groupOrder = <String>['model', 'effort', 'permission'];

IconData _groupIcon(String group) {
  switch (group) {
    case 'model':
      return Icons.auto_awesome_outlined;
    case 'effort':
      return Icons.psychology_outlined;
    case 'permission':
      return Icons.shield_outlined;
    default:
      return Icons.tune_rounded;
  }
}

String _groupLabel(AppStrings l10n, String group) {
  switch (group) {
    case 'model':
      return l10n.agentModel;
    case 'effort':
      return l10n.agentEffort;
    case 'permission':
      return l10n.agentPermission;
    default:
      return group;
  }
}

String _groupTitle(AppStrings l10n, String group) {
  switch (group) {
    case 'model':
      return l10n.agentModelTitle;
    case 'effort':
      return l10n.agentEffortTitle;
    case 'permission':
      return l10n.agentPermissionTitle;
    default:
      return group;
  }
}

String _optionLabel(AppStrings l10n, String group, AgentOption option) {
  if (group != 'effort') return option.label;
  switch (option.id) {
    case 'minimal':
      return l10n.agentEffortMinimal;
    case 'low':
      return l10n.agentEffortLow;
    case 'medium':
      return l10n.agentEffortMedium;
    case 'high':
      return l10n.agentEffortHigh;
    case 'xhigh':
      return l10n.agentEffortExtraHigh;
    case 'max':
      return l10n.agentEffortMax;
    default:
      return option.label;
  }
}

class AgentControlsButtons extends StatefulWidget {
  const AgentControlsButtons({
    required this.backend,
    required this.agentKey,
    this.onOpenPage,
    super.key,
  });

  final BackendClient backend;
  final String agentKey;
  final VoidCallback? onOpenPage;

  @override
  State<AgentControlsButtons> createState() => _AgentControlsButtonsState();
}

class _AgentControlsButtonsState extends State<AgentControlsButtons> {
  AgentOptionsCatalog? _catalog;
  AgentSettings _settings = AgentSettings.empty;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AgentControlsButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentKey != widget.agentKey) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final List<Object> results = await Future.wait(<Future<Object>>[
        widget.backend.fetchAgentOptions(widget.agentKey),
        widget.backend.fetchAgentSettings(widget.agentKey),
      ]);
      if (!mounted) return;
      setState(() {
        _catalog = results[0] as AgentOptionsCatalog;
        _settings = results[1] as AgentSettings;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _openGroup(String group) async {
    final AgentOptionsCatalog? catalog = _catalog;
    if (catalog == null) return;
    final NavigatorState navigator = Navigator.of(context);
    widget.onOpenPage?.call();
    final AgentSettings? result = await navigator.push<AgentSettings>(
      MaterialPageRoute<AgentSettings>(
        builder: (BuildContext ctx) => _AgentOptionPage(
          backend: widget.backend,
          agentKey: widget.agentKey,
          group: group,
          catalog: catalog,
          current: _settings[group] ?? catalog.defaults[group] ?? '',
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() => _settings = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_failed) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(context.l10n.agentControlsLoadFailed),
        ),
      );
    }
    final AgentOptionsCatalog? catalog = _catalog;
    if (catalog == null) return const SizedBox.shrink();
    final List<String> groups = _groupOrder
        .where((String group) => catalog.supportsGroup(group))
        .toList(growable: false);
    if (groups.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 14,
      runSpacing: 14,
      children: <Widget>[
        for (final String group in groups)
          ComposerActionButton(
            icon: _groupIcon(group),
            label: _groupLabel(context.l10n, group),
            onPressed: () => _openGroup(group),
          ),
      ],
    );
  }
}

class ComposerActionButton extends StatelessWidget {
  const ComposerActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 92,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 7),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Page listing the choices for one control group. For the `model` group it also
/// shows the installed CLI version and an "Update CLI" button so a user who
/// doesn't see the newest model can pull it in. Saves on selection and pops with
/// the new AgentSettings.
class _AgentOptionPage extends StatefulWidget {
  const _AgentOptionPage({
    required this.backend,
    required this.agentKey,
    required this.group,
    required this.catalog,
    required this.current,
  });

  final BackendClient backend;
  final String agentKey;
  final String group;
  final AgentOptionsCatalog catalog;
  final String current;

  @override
  State<_AgentOptionPage> createState() => _AgentOptionPageState();
}

class _AgentOptionPageState extends State<_AgentOptionPage> {
  late AgentOptionsCatalog _catalog;
  late String _current;
  bool _saving = false;
  bool _updating = false;
  String _version = '';

  bool get _isModel => widget.group == 'model';

  @override
  void initState() {
    super.initState();
    _catalog = widget.catalog;
    _current = widget.current;
    if (_isModel) _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final String version =
          await widget.backend.fetchAgentVersion(widget.agentKey);
      if (!mounted) return;
      setState(() => _version = version);
    } catch (_) {
      // Version label is best-effort.
    }
  }

  Future<void> _select(String id) async {
    if (_saving || _updating) return;
    setState(() {
      _saving = true;
      _current = id;
    });
    try {
      final AgentSettings settings = await widget.backend
          .updateAgentSetting(widget.agentKey, widget.group, id);
      if (!mounted) return;
      Navigator.of(context).pop(settings);
    } catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.agentSettingSaveFailed(err))),
      );
    }
  }

  Future<void> _update() async {
    final AppStrings l10n = context.l10n;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.agentUpdateConfirmTitle(widget.agentKey)),
        content: Text(l10n.agentUpdateConfirmBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.agentUpdateCli),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _updating = true);
    try {
      final AgentUpdateResult result =
          await widget.backend.updateAgentCli(widget.agentKey);
      final AgentOptionsCatalog options =
          await widget.backend.fetchAgentOptions(widget.agentKey);
      if (!mounted) return;
      setState(() {
        _catalog = options;
        _version = result.after.isNotEmpty ? result.after : _version;
        _updating = false;
      });
      final String message = result.changed
          ? l10n.agentUpdateDone(result.before, result.after)
          : l10n.agentUpdateNoChange;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (err) {
      if (!mounted) return;
      setState(() => _updating = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.agentUpdateFailed(err))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings l10n = context.l10n;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<AgentOption> options = _catalog.optionsFor(widget.group);

    return Scaffold(
      appBar: AppBar(
        title: Text(_groupTitle(l10n, widget.group)),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView.separated(
                itemCount: options.length,
                separatorBuilder: (BuildContext context, int index) =>
                    Divider(height: 1, color: colors.outlineVariant),
                itemBuilder: (BuildContext ctx, int index) {
                  final AgentOption option = options[index];
                  final bool selected = option.id == _current;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 4,
                    ),
                    onTap:
                        _saving || _updating ? null : () => _select(option.id),
                    leading: Icon(
                      selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color:
                          selected ? colors.primary : colors.onSurfaceVariant,
                    ),
                    title: Text(_optionLabel(l10n, widget.group, option)),
                    subtitle: option.description == null
                        ? null
                        : Text(option.description!),
                  );
                },
              ),
            ),
            if (_isModel) _buildUpdateFooter(l10n, colors),
          ],
        ),
      ),
    );
  }

  Widget _buildUpdateFooter(AppStrings l10n, ColorScheme colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            l10n.agentUpdateMissingModel,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: _updating ? null : _update,
                icon: _updating
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.system_update_alt_rounded, size: 18),
                label:
                    Text(_updating ? l10n.agentUpdating : l10n.agentUpdateCli),
              ),
              const SizedBox(width: 12),
              if (_version.isNotEmpty)
                Expanded(
                  child: Text(
                    l10n.agentCliVersion(_version),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
