// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/machine_credential.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/chat_wallpaper.dart';
import '../cli_agents/cli_agents_controller.dart';
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

  @override
  void initState() {
    super.initState();
    widget.machinesController.addListener(_onMachineChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    widget.machinesController.removeListener(_onMachineChanged);
    super.dispose();
  }

  void _onMachineChanged() {
    if (widget.machinesController.activeMachine?.id == _lastMachineId) {
      setState(() {});
      return;
    }
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    _lastMachineId = widget.machinesController.activeMachine?.id;
    if (_lastMachineId == null) {
      setState(() {
        _recentWorkdirs = const <String>[];
        _loading = false;
      });
      return;
    }

    setState(() => _loading = true);
    final Future<void> workdir = widget.chatController.refreshWorkdir();
    List<String> recent = const <String>[];
    try {
      recent = await widget.chatController.backend.recentWorkdirs();
    } catch (_) {
      // An offline backend should not break the home page.
    }
    await workdir;
    if (!mounted) return;
    setState(() {
      _recentWorkdirs = recent.take(3).toList(growable: false);
      _loading = false;
    });
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
                        _WorkdirTile(dir: workdir, current: true),
                      ],
                    ),
                  ],
                  const SizedBox(height: 20),
                  _HomeSection(
                    title: strings.recentWorkspaces,
                    emptyText: strings.noRecentWorkspaces,
                    children: <Widget>[
                      for (final String dir in _recentWorkdirs)
                        _WorkdirTile(dir: dir),
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
  const _WorkdirTile({required this.dir, this.current = false});

  final String dir;

  /// The device's active workdir, marked with an open, accented folder.
  final bool current;

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
