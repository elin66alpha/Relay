// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/models/machine_credential.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/error_text.dart';
import '../../core/widgets/chat_wallpaper.dart';
import '../cli_agents/cli_agents_controller.dart';
import '../filesystem/file_system_screen.dart';
import '../machines/machine_credentials_controller.dart';
import '../settings/getting_started_screen.dart';
import '../settings/whats_new_screen.dart';
import 'bot_chat_controller.dart';
import 'cli_agents_drawer.dart';

class HomeNavigationPage extends StatefulWidget {
  const HomeNavigationPage({
    super.key,
    required this.agentsController,
    required this.chatController,
    required this.machinesController,
  });

  final CliAgentsController agentsController;
  final BotChatController chatController;
  final MachineCredentialsController machinesController;

  @override
  State<HomeNavigationPage> createState() => _HomeNavigationPageState();
}

class _HomeNavigationPageState extends State<HomeNavigationPage> {
  bool _loading = false;
  List<String> _recentWorkdirs = const <String>[];
  String? _lastMachineId;
  int _refreshSequence = 0;

  @override
  void initState() {
    super.initState();
    widget.machinesController.addListener(_onMachineChanged);
    widget.chatController.addListener(_onWorkdirChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    widget.machinesController.removeListener(_onMachineChanged);
    widget.chatController.removeListener(_onWorkdirChanged);
    super.dispose();
  }

  void _onWorkdirChanged() {
    if (mounted) setState(() {});
  }

  void _onMachineChanged() {
    if (widget.machinesController.activeMachine?.id == _lastMachineId) {
      setState(() {});
      return;
    }
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final int sequence = ++_refreshSequence;
    final String? machineId = widget.machinesController.activeMachine?.id;
    final bool machineChanged = machineId != _lastMachineId;
    _lastMachineId = machineId;
    if (machineId == null) {
      setState(() {
        _recentWorkdirs = const <String>[];
        _loading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      if (machineChanged) _recentWorkdirs = const <String>[];
    });
    final Future<void> workdir = widget.chatController.refreshWorkdir();
    List<String> recent = const <String>[];
    try {
      recent = await widget.chatController.backend.recentWorkdirs();
    } catch (_) {
      // An offline backend should not break the home page.
    }
    await workdir;
    if (!mounted ||
        sequence != _refreshSequence ||
        machineId != widget.machinesController.activeMachine?.id) {
      return;
    }
    setState(() {
      _recentWorkdirs = recent.take(3).toList(growable: false);
      _loading = false;
    });
  }

  Future<void> _openFileSystem() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FileSystemScreen(
          backend: widget.chatController.backend,
          onSetWorkdir: widget.chatController.setWorkdir,
        ),
      ),
    );
    if (mounted) unawaited(_refresh());
  }

  Future<void> _selectRecentWorkdir(String dir, String machineId) async {
    if (_loading || machineId != widget.machinesController.activeMachine?.id) {
      return;
    }
    if (widget.chatController.activeWorkdir == dir) {
      await _openFileSystem();
      return;
    }
    try {
      await widget.chatController.setWorkdir(dir);
      if (!mounted ||
          machineId != widget.machinesController.activeMachine?.id) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.workdirUpdated)),
      );
      unawaited(_refresh());
    } catch (err) {
      if (!mounted ||
          machineId != widget.machinesController.activeMachine?.id) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            err is BackendException && err.code == 'WORKDIR_BUSY'
                ? context.l10n.workdirBusy
                : friendlyErrorText(context.l10n, err),
          ),
        ),
      );
    }
  }

  void _openWhatsNew() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const WhatsNewScreen()),
    );
  }

  void _openGettingStarted() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const GettingStartedScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final MachineCredential? machine = widget.machinesController.activeMachine;
    final String? workdir = widget.chatController.activeWorkdir;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        children: <Widget>[
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_loading) ...<Widget>[
                    const LinearProgressIndicator(minHeight: 2),
                    const SizedBox(height: 12),
                  ],
                  _HomeSection(
                    title: strings.currentMachine,
                    children: <Widget>[
                      if (machine == null)
                        ListTile(
                          leading: const Icon(Icons.link_off_rounded),
                          title: Text(strings.notConnected),
                          subtitle: Text(strings.importOrChooseMachine),
                        )
                      else
                        ActiveMachineStatusTile(
                          activeMachine: machine,
                          chatController: widget.chatController,
                          agentsController: widget.agentsController,
                          framed: false,
                        ),
                    ],
                  ),
                  if (workdir != null) ...<Widget>[
                    const SizedBox(height: 20),
                    _HomeSection(
                      title: strings.currentWorkspace,
                      children: <Widget>[
                        _WorkdirTile(
                          dir: workdir,
                          current: true,
                          onTap: _loading || machine == null
                              ? null
                              : _openFileSystem,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  _HomeSection(
                    title: strings.recentWorkspaces,
                    emptyText: strings.noRecentWorkspaces,
                    children: <Widget>[
                      for (final String dir in _recentWorkdirs)
                        _WorkdirTile(
                          dir: dir,
                          current: dir == workdir,
                          onTap: _loading || machine == null
                              ? null
                              : () => _selectRecentWorkdir(dir, machine.id),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _HomeSection(
                    title: strings.whatsNew,
                    children: <Widget>[
                      ListTile(
                        leading: const Icon(Icons.auto_awesome_outlined),
                        title: Text(strings.whatsNewHomeTitle),
                        subtitle: Text(whatsNewSummary(strings)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openWhatsNew,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _HomeSection(
                    title: strings.tutorial,
                    children: <Widget>[
                      ListTile(
                        leading: const Icon(Icons.school_outlined),
                        title: Text(strings.gettingStarted),
                        subtitle: Text(strings.gettingStartedHomeHint),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openGettingStarted,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeSection extends StatelessWidget {
  const _HomeSection({
    required this.title,
    this.emptyText = '',
    required this.children,
  });

  final String title;
  final String emptyText;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
        const SizedBox(height: 8),
        _HomeSectionCard(
          child: children.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    emptyText,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : Column(
                  children: <Widget>[
                    for (int index = 0; index < children.length; index += 1)
                      Column(
                        children: <Widget>[
                          if (index > 0) const Divider(height: 1),
                          children[index],
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _HomeSectionCard extends StatelessWidget {
  const _HomeSectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (WallpaperScope.enabledOf(context)) {
      final ThemeData theme = Theme.of(context);
      return ChatChromeSurface(
        acrylic: true,
        color: theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow,
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
        borderRadius: BorderRadius.circular(AppTheme.panelRadius),
        child: child,
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: child,
    );
  }
}

class _WorkdirTile extends StatelessWidget {
  const _WorkdirTile({
    required this.dir,
    this.current = false,
    this.onTap,
  });

  final String dir;

  /// The device's active workdir, marked with an open, accented folder.
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ListTile(
      leading: current
          ? Icon(Icons.folder_open_rounded, color: colors.primary)
          : const Icon(Icons.folder_outlined),
      title: Text(
        workdirName(dir),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        dir,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTheme.mono(colors.onSurfaceVariant).copyWith(fontSize: 12),
      ),
      trailing: onTap != null ? const Icon(Icons.chevron_right) : null,
      onTap: onTap,
    );
  }
}

/// The folder name of a work directory ("Relay" for "/home/me/Relay" or
/// "C:\\code\\Relay"), or the whole path for a filesystem root.
String workdirName(String dir) {
  final String name = dir
      .split(RegExp(r'[\\/]'))
      .lastWhere((String part) => part.isNotEmpty, orElse: () => '');
  return name.isEmpty ? dir : name;
}
