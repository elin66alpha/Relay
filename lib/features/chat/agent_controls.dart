import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/widgets/chat_wallpaper.dart';
import '../../core/models/agent_options.dart';

/// Per-agent Model / Effort / Permission / Fast controls shown in the composer's
/// "+" drawer. Capability-aware: only groups the agent supports are rendered
/// for the current workdir+agent scope, so every device in that scope shares
/// them.

const List<String> _groupOrder = <String>['model', 'effort', 'permission'];

/// Option catalogs describe what the installed CLI ships, not what the current
/// scope selected, so one fetch serves every workdir on a machine. They are kept
/// across opens because the composer rebuilds this widget every time its "+"
/// drawer opens: without a cache each open showed a spinner and then jumped to
/// its real height while the panel was still animating.
final Map<String, AgentOptionsCatalog> _catalogCache =
    <String, AgentOptionsCatalog>{};

/// Drop the cached catalogs. Call this when the app switches machines: another
/// backend host can have different CLIs, and different versions of them.
void clearAgentOptionsCache() => _catalogCache.clear();

/// Agents whose CLI update is running. It outlives the drawer, which can close
/// and reopen during an update that takes minutes.
final ValueNotifier<Set<String>> _updatingAgents =
    ValueNotifier<Set<String>>(<String>{});

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

String _modelGroupTitle(AppStrings l10n, String group) {
  switch (group) {
    case 'paid':
      return l10n.agentModelsPaid;
    case 'legacy':
      return l10n.agentModelsLegacy;
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
    case 'extra-high':
      return l10n.agentEffortExtraHigh;
    case 'max':
      return l10n.agentEffortMax;
    case 'none':
      return l10n.agentEffortNone;
    case 'ultra':
      return l10n.agentEffortUltra;
    default:
      return option.label;
  }
}

class AgentControlsButtons extends StatefulWidget {
  const AgentControlsButtons({
    required this.backend,
    required this.agentKey,
    this.sessionId,
    this.onOpenPage,
    super.key,
  });

  final BackendClient backend;
  final String agentKey;
  // The chat session the settings belong to; null addresses Main.
  final String? sessionId;
  final VoidCallback? onOpenPage;

  @override
  State<AgentControlsButtons> createState() => _AgentControlsButtonsState();
}

class _AgentControlsButtonsState extends State<AgentControlsButtons> {
  AgentOptionsCatalog? _catalog;
  AgentSettings _settings = AgentSettings.empty;
  // Settings are per session, so unlike the catalog they are always fetched. Held as a future too: the buttons now render from the cached
  // catalog before this lands, so a quick tap must wait for the real selection
  // instead of opening a page on the defaults.
  Future<AgentSettings> _settingsReady =
      Future<AgentSettings>.value(AgentSettings.empty);
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
    if (oldWidget.agentKey != widget.agentKey ||
        oldWidget.sessionId != widget.sessionId) {
      _load();
    }
  }

  void _adoptSettings(AgentSettings settings) {
    _settings = settings;
    _settingsReady = Future<AgentSettings>.value(settings);
  }

  Future<void> _load() async {
    final String agentKey = widget.agentKey;
    final String? sessionId = widget.sessionId;
    final AgentOptionsCatalog? cached = _catalogCache[agentKey];
    final Future<AgentSettings> pending =
        widget.backend.fetchAgentSettings(agentKey, sessionId: sessionId);
    setState(() {
      _catalog = cached;
      _settingsReady = pending;
      // A cached catalog already says which buttons exist, so the panel opens at
      // its final size and this fetch only corrects it.
      _loading = cached == null;
      _failed = false;
    });
    try {
      final List<Object> results = await Future.wait(<Future<Object>>[
        widget.backend.fetchAgentOptions(agentKey),
        pending,
      ]);
      if (!mounted ||
          agentKey != widget.agentKey ||
          sessionId != widget.sessionId) {
        return;
      }
      final AgentOptionsCatalog catalog = results[0] as AgentOptionsCatalog;
      _catalogCache[agentKey] = catalog;
      setState(() {
        _catalog = catalog;
        _adoptSettings(results[1] as AgentSettings);
        _loading = false;
      });
    } catch (_) {
      if (!mounted ||
          agentKey != widget.agentKey ||
          sessionId != widget.sessionId) {
        return;
      }
      setState(() {
        _loading = false;
        // A cached catalog is still worth showing; only a cold failure is fatal.
        _failed = _catalog == null;
      });
    }
  }

  Future<AgentSettings> _resolvedSettings() async {
    try {
      return await _settingsReady;
    } catch (_) {
      return _settings;
    }
  }

  Future<void> _openGroup(String group) async {
    final AgentOptionsCatalog? catalog = _catalog;
    if (catalog == null) return;
    final AgentSettings settings = await _resolvedSettings();
    if (!mounted) return;
    final String? modelId =
        catalog.resolveSelection('model', settings['model']);
    final String current = catalog.resolveSelection(
          group,
          settings[group],
          modelId: modelId,
        ) ??
        '';
    final NavigatorState navigator = Navigator.of(context);
    widget.onOpenPage?.call();
    final AgentSettings? result = await navigator.push<AgentSettings>(
      MaterialPageRoute<AgentSettings>(
        builder: (BuildContext ctx) => _AgentOptionPage(
          backend: widget.backend,
          agentKey: widget.agentKey,
          sessionId: widget.sessionId,
          group: group,
          catalog: catalog,
          current: current,
          modelId: modelId,
          fastEnabled: settings['fast'] == 'on',
        ),
      ),
    );
    if (!mounted || result == null) return;
    // The page saved the selection; adopting it is what a reload would have
    // fetched. A CLI update meanwhile may have refreshed the cached catalog.
    setState(() {
      _catalog = _catalogCache[widget.agentKey] ?? catalog;
      _adoptSettings(result);
    });
  }

  Future<void> _updateCli() async {
    final AppStrings l10n = context.l10n;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String agentKey = widget.agentKey;
    final String? sessionId = widget.sessionId;
    String version = '';
    try {
      version = await widget.backend.fetchAgentVersion(agentKey);
    } catch (_) {
      // The version line is best-effort.
    }
    if (!mounted) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l10n.agentUpdateConfirmTitle(agentKey)),
        content: Text(
          version.isEmpty
              ? l10n.agentUpdateConfirmBody
              : '${l10n.agentCliVersion(version)}\n\n${l10n.agentUpdateConfirmBody}',
        ),
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
    if (confirmed != true || _updatingAgents.value.contains(agentKey)) return;
    _updatingAgents.value = <String>{..._updatingAgents.value, agentKey};
    try {
      final AgentUpdateResult result =
          await widget.backend.updateAgentCli(agentKey);
      if (!result.ok) {
        final String detail = result.timedOut
            ? l10n.agentUpdateTimedOut
            : result.output.isNotEmpty
                ? result.output
                : l10n.agentUpdateCommandFailed;
        final String visibleDetail =
            detail.length > 400 ? '${detail.substring(0, 400)}...' : detail;
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.agentUpdateFailed(visibleDetail))),
        );
        return;
      }
      final List<Object> refreshed = await Future.wait(<Future<Object>>[
        widget.backend.fetchAgentOptions(agentKey),
        widget.backend.fetchAgentSettings(agentKey, sessionId: sessionId),
      ]);
      // The new binary can ship different models, so replace what the option
      // pages draw from.
      final AgentOptionsCatalog catalog = refreshed[0] as AgentOptionsCatalog;
      _catalogCache[agentKey] = catalog;
      if (mounted &&
          agentKey == widget.agentKey &&
          sessionId == widget.sessionId) {
        setState(() {
          _catalog = catalog;
          _adoptSettings(refreshed[1] as AgentSettings);
        });
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.changed
                ? l10n.agentUpdateDone(result.before, result.after)
                : l10n.agentUpdateNoChange,
          ),
        ),
      );
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.agentUpdateFailed(err))),
      );
    } finally {
      _updatingAgents.value = <String>{..._updatingAgents.value}
        ..remove(agentKey);
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
    final String? modelId = catalog.resolveSelection(
      'model',
      _settings['model'],
    );
    final List<String> groups = _groupOrder
        .where(
          (String group) =>
              catalog.supportsGroup(group) &&
              catalog.optionsFor(group, modelId: modelId).isNotEmpty,
        )
        .toList(growable: false);

    return ComposerActionRow(
      children: <Widget>[
        for (final String group in groups)
          ComposerActionButton(
            icon: _groupIcon(group),
            label: _groupLabel(context.l10n, group),
            onPressed: () => _openGroup(group),
          ),
        ValueListenableBuilder<Set<String>>(
          valueListenable: _updatingAgents,
          builder: (BuildContext context, Set<String> updating, _) {
            final bool busy = updating.contains(widget.agentKey);
            return ComposerActionButton(
              icon: Icons.system_update_alt_rounded,
              label: busy
                  ? context.l10n.agentUpdating
                  : context.l10n.agentUpdateCli,
              onPressed: busy ? null : _updateCli,
            );
          },
        ),
      ],
    );
  }
}

/// One row of the composer's "+" drawer. Always four equal columns, on phones
/// and desktops alike, so the drawer's two rows line up as a 2x4 grid.
class ComposerActionRow extends StatelessWidget {
  const ComposerActionRow({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // Capped and centered, so a wide screen keeps the grid together instead
    // of spreading four columns across the whole composer.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < 4; i++)
              Expanded(
                child:
                    i < children.length ? children[i] : const SizedBox.shrink(),
              ),
          ],
        ),
      ),
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

  /// Null disables the action.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 92,
      child: Opacity(
        opacity: onPressed == null ? 0.4 : 1,
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
                    color: WallpaperScope.enabledOf(context)
                        ? colors.surface.withValues(alpha: 0.18)
                        : colors.surface,
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
      ),
    );
  }
}

/// Page listing the choices for one control group. Saves on selection and pops
/// with the new AgentSettings.
class _AgentOptionPage extends StatefulWidget {
  const _AgentOptionPage({
    required this.backend,
    required this.agentKey,
    required this.sessionId,
    required this.group,
    required this.catalog,
    required this.current,
    required this.modelId,
    required this.fastEnabled,
    this.modelGroup,
  });

  final BackendClient backend;
  final String agentKey;
  final String? sessionId;
  final String group;
  final AgentOptionsCatalog catalog;
  final String current;
  final String? modelId;
  final bool fastEnabled;

  /// The model group this page lists; null is the first page, which lists
  /// ungrouped models and links to each group at the bottom.
  final String? modelGroup;

  @override
  State<_AgentOptionPage> createState() => _AgentOptionPageState();
}

class _AgentOptionPageState extends State<_AgentOptionPage> {
  late AgentOptionsCatalog _catalog;
  late String _current;
  String? _modelId;
  bool _saving = false;
  bool _savingFast = false;
  late bool _fastEnabled;

  bool get _isModel => widget.group == 'model';
  bool get _isFirstModelPage => _isModel && widget.modelGroup == null;

  @override
  void initState() {
    super.initState();
    _catalog = widget.catalog;
    _fastEnabled = widget.fastEnabled;
    _modelId = _catalog.resolveSelection('model', widget.modelId);
    _current = _catalog.resolveSelection(
          widget.group,
          widget.current,
          modelId: _modelId,
        ) ??
        '';
  }

  Future<void> _select(String id) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _current = id;
    });
    try {
      final AgentSettings settings = await widget.backend.updateAgentSetting(
        widget.agentKey,
        widget.group,
        id,
        sessionId: widget.sessionId,
      );
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

  Future<void> _toggleFast(bool enabled) async {
    if (_savingFast || _saving) return;
    setState(() => _savingFast = true);
    try {
      await widget.backend.updateAgentSetting(
        widget.agentKey,
        'fast',
        enabled ? 'on' : 'off',
        sessionId: widget.sessionId,
      );
      if (!mounted) return;
      setState(() => _fastEnabled = enabled);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.agentSettingSaveFailed(err))),
      );
    } finally {
      if (mounted) setState(() => _savingFast = false);
    }
  }

  Future<void> _openModelGroup(String modelGroup) async {
    final AgentSettings? result = await Navigator.of(context).push(
      MaterialPageRoute<AgentSettings>(
        builder: (BuildContext ctx) => _AgentOptionPage(
          backend: widget.backend,
          agentKey: widget.agentKey,
          sessionId: widget.sessionId,
          group: widget.group,
          catalog: _catalog,
          current: _current,
          modelId: _modelId,
          fastEnabled: _fastEnabled,
          modelGroup: modelGroup,
        ),
      ),
    );
    if (!mounted || result == null) return;
    Navigator.of(context).pop(result);
  }

  Widget? _modelGroupLinks(AppStrings l10n, List<AgentOption> all) {
    if (!_isFirstModelPage) return null;
    final Set<String> groups = <String>{
      for (final AgentOption option in all)
        if (option.group != null) option.group!,
    };
    if (groups.isEmpty) return null;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Divider(height: 1),
          for (final String group in groups)
            _modelGroupLink(l10n, group, <AgentOption>[
              for (final AgentOption option in all)
                if (option.group == group) option,
            ]),
        ],
      ),
    );
  }

  Widget _modelGroupLink(
    AppStrings l10n,
    String group,
    List<AgentOption> members,
  ) {
    final AgentOption? selected = members
        .where((AgentOption option) => option.id == _current)
        .firstOrNull;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Icon(
        group == 'paid' ? Icons.credit_card_outlined : Icons.history_rounded,
      ),
      title: Text('${_modelGroupTitle(l10n, group)} (${members.length})'),
      subtitle: selected == null
          ? null
          : Text(l10n.agentModelsCurrent(selected.label)),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: _saving ? null : () => _openModelGroup(group),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings l10n = context.l10n;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<AgentOption> all = _catalog.optionsFor(
      widget.group,
      modelId: _modelId,
    );
    final List<AgentOption> options = _isModel
        ? all
            .where((AgentOption option) => option.group == widget.modelGroup)
            .toList()
        : all;
    final bool showFast = _isFirstModelPage && _catalog.supportsGroup('fast');

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.modelGroup == null
              ? _groupTitle(l10n, widget.group)
              : _modelGroupTitle(l10n, widget.modelGroup!),
        ),
      ),
      bottomNavigationBar: _modelGroupLinks(l10n, all),
      body: SafeArea(
        child: ListView.separated(
          itemCount: options.length + (showFast ? 1 : 0),
          separatorBuilder: (BuildContext context, int index) =>
              Divider(height: 1, color: colors.outlineVariant),
          itemBuilder: (BuildContext ctx, int index) {
            if (showFast && index == 0) {
              return SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 4,
                ),
                secondary: const Icon(Icons.bolt_rounded),
                title: Text(l10n.agentFastMode),
                subtitle: Text(l10n.agentFastModeHint),
                value: _fastEnabled,
                onChanged: _savingFast || _saving ? null : _toggleFast,
              );
            }
            final int optionIndex = index - (showFast ? 1 : 0);
            final AgentOption option = options[optionIndex];
            final bool selected = option.id == _current;
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 4,
              ),
              onTap: _saving ? null : () => _select(option.id),
              leading: Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
              title: Text(_optionLabel(l10n, widget.group, option)),
              subtitle:
                  option.description == null ? null : Text(option.description!),
            );
          },
        ),
      ),
    );
  }
}
