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
import '../settings/tutorial_screen.dart';
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
      _recentWorkdirs = recent.take(5).toList(growable: false);
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

  void _openTutorial() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const TutorialScreen()),
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
                    title: strings.tutorial,
                    children: <Widget>[
                      ListTile(
                        leading: const Icon(Icons.school_outlined),
                        title: Text(strings.tutorialHomeTitle),
                        subtitle: Text(strings.tutorialHomeHint),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _openTutorial,
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

/// Opened from the solo chat title: the current workspace, the seven most
/// recent others, and File System pinned at the bottom. Choosing a recent
/// workspace switches to it and returns to the chat.
class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({super.key, required this.chatController});

  final BotChatController chatController;

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage> {
  bool _loading = true;
  List<String> _recentWorkdirs = const <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final Future<void> workdir = widget.chatController.refreshWorkdir();
    List<String> recent = const <String>[];
    try {
      recent = await widget.chatController.backend.recentWorkdirs();
    } catch (_) {
      // An offline backend still leaves File System reachable.
    }
    await workdir;
    if (!mounted) return;
    setState(() {
      _recentWorkdirs = recent;
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

  Future<void> _selectWorkdir(String dir) async {
    if (_loading) return;
    setState(() => _loading = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AppStrings strings = context.l10n;
    try {
      await widget.chatController.setWorkdir(dir);
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(strings.workdirUpdated)));
    } catch (err) {
      if (!mounted) return;
      setState(() => _loading = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            err is BackendException && err.code == 'WORKDIR_BUSY'
                ? strings.workdirBusy
                : friendlyErrorText(strings, err),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(strings.workspaces)),
      body: ListenableBuilder(
        listenable: widget.chatController,
        builder: (BuildContext context, Widget? _) {
          final String? workdir = widget.chatController.activeWorkdir;
          final List<String> recent = _recentWorkdirs
              .where((String dir) => dir != workdir)
              .take(7)
              .toList(growable: false);
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              children: <Widget>[
                _HomeColumn(
                  children: <Widget>[
                    if (_loading) ...<Widget>[
                      const LinearProgressIndicator(minHeight: 2),
                      const SizedBox(height: 12),
                    ],
                    if (workdir != null) ...<Widget>[
                      _HomeSection(
                        title: strings.currentWorkspace,
                        children: <Widget>[
                          _WorkdirTile(
                            dir: workdir,
                            current: true,
                            onTap: _loading ? null : _openFileSystem,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                    _HomeSection(
                      title: strings.recentWorkspaces,
                      emptyText: strings.noRecentWorkspaces,
                      children: <Widget>[
                        for (final String dir in recent)
                          _WorkdirTile(
                            dir: dir,
                            onTap: _loading ? null : () => _selectWorkdir(dir),
                          ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: _HomeColumn(
          children: <Widget>[
            _HomeSectionCard(
              child: ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: Text(strings.fileSystem),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openFileSystem,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Centres [children] at the home page's 840 px reading width.
class _HomeColumn extends StatelessWidget {
  const _HomeColumn({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 840),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
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
