import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/models/machine_credential.dart';
import '../../core/models/cli_agent.dart';
import '../../core/settings/app_settings_controller.dart';
import '../chat/bot_chat_controller.dart';
import '../machines/machine_credentials_controller.dart';
import '../machines/machine_credentials_screen.dart';
import '../settings/app_settings_screen.dart';
import '../cards/card_deck_screen.dart';
import '../filesystem/file_system_screen.dart';
import 'cli_agents_controller.dart';

class CliAgentsDrawer extends StatelessWidget {
  const CliAgentsDrawer({
    required this.agentsController,
    required this.chatController,
    required this.machinesController,
    required this.settingsController,
    this.closeOnAction = true,
    super.key,
  });

  final CliAgentsController agentsController;
  final BotChatController chatController;
  final MachineCredentialsController machinesController;
  final AppSettingsController settingsController;
  final bool closeOnAction;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        agentsController,
        machinesController,
      ]),
      builder: (BuildContext context, Widget? _) {
        final String activeKey = agentsController.activeAgentKey;
        final MachineCredential? activeMachine =
            machinesController.activeMachine;
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  context.l10n.appName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            ActiveMachineStatusTile(
              activeMachine: activeMachine,
              chatController: chatController,
            ),
            Expanded(
              child: ListView(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.vpn_key_outlined),
                    title: Text(context.l10n.manageCredentials),
                    onTap: () {
                      if (closeOnAction) Navigator.of(context).pop();
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => MachineCredentialsScreen(
                            machinesController: machinesController,
                          ),
                        ),
                      );
                    },
                  ),
                  const Divider(height: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Text(
                      context.l10n.cliAgents,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  for (final CliAgent agent in agentsController.agents)
                    ListTile(
                      leading: Icon(_iconFor(agent.key)),
                      title: Text(agent.label),
                      subtitle: Text(
                        agent.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      selected: agent.key == activeKey,
                      onTap: () async {
                        await agentsController.setActive(agent.key);
                        if (context.mounted && closeOnAction) {
                          Navigator.of(context).pop();
                        }
                      },
                    ),
                  const Divider(height: 16),
                  ListTile(
                    leading: const Icon(Icons.style_outlined),
                    title: Text(context.l10n.cardMode),
                    subtitle: Text(
                      context.l10n.cardModeSubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      if (closeOnAction) Navigator.of(context).pop();
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => CardDeckScreen(
                            agentsController: agentsController,
                            chatController: chatController,
                            machinesController: machinesController,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text(context.l10n.fileSystem),
              onTap: () {
                if (closeOnAction) Navigator.of(context).pop();
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => FileSystemScreen(
                      chatController: chatController,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: Text(context.l10n.settings),
              onTap: () {
                if (closeOnAction) Navigator.of(context).pop();
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => AppSettingsScreen(
                      settingsController: settingsController,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

IconData _iconFor(String key) {
  return switch (key) {
    'codex' => Icons.terminal_rounded,
    'agy' => Icons.auto_awesome_motion_outlined,
    _ => Icons.code_rounded,
  };
}

class ActiveMachineStatusTile extends StatefulWidget {
  const ActiveMachineStatusTile({
    required this.activeMachine,
    required this.chatController,
    super.key,
  });

  final MachineCredential? activeMachine;
  final BotChatController chatController;

  @override
  State<ActiveMachineStatusTile> createState() =>
      _ActiveMachineStatusTileState();
}

class _ActiveMachineStatusTileState extends State<ActiveMachineStatusTile> {
  bool _isLoading = false;
  bool _isOnline = false;
  String? _statusText;
  int _statusRequestSerial = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkStatus();
    });
  }

  @override
  void didUpdateWidget(ActiveMachineStatusTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeMachine?.id != widget.activeMachine?.id) {
      _checkStatus();
    }
  }

  Future<void> _checkStatus() async {
    final int requestSerial = ++_statusRequestSerial;
    final MachineCredential? machine = widget.activeMachine;
    final AppStrings strings = context.l10n;
    if (machine == null) {
      if (mounted) {
        setState(() {
          _statusText = null;
          _isOnline = false;
          _isLoading = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLoading = true;
        _statusText = null;
      });
    }

    try {
      final String text = await widget.chatController
          .statusText(strings, timeout: const Duration(seconds: 6))
          .timeout(const Duration(seconds: 8));
      if (mounted &&
          requestSerial == _statusRequestSerial &&
          widget.activeMachine?.id == machine.id) {
        setState(() {
          _statusText = text;
          _isOnline = true;
          _isLoading = false;
        });
      }
    } catch (err) {
      if (mounted &&
          requestSerial == _statusRequestSerial &&
          widget.activeMachine?.id == machine.id) {
        setState(() {
          _statusText = strings.statusLoadFailed(err);
          _isOnline = false;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _showStatusDialog() async {
    if (widget.activeMachine == null) return;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setStateDialog) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: Row(
                children: <Widget>[
                  Icon(
                    Icons.lens,
                    color: _isLoading
                        ? Colors.grey
                        : (_isOnline
                            ? const Color(0xFF10B981)
                            : const Color(0xFFEF4444)),
                    size: 14,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.activeMachine!.displayName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              content: Container(
                constraints: const BoxConstraints(maxHeight: 250),
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: _isLoading
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24.0),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      : SelectableText(
                          _statusText ?? context.l10n.noStatus,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: _isLoading
                      ? null
                      : () async {
                          setStateDialog(() {
                            _isLoading = true;
                          });
                          await _checkStatus();
                          if (dialogContext.mounted) {
                            setStateDialog(() {});
                          }
                        },
                  child: Text(context.l10n.refresh),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(context.l10n.close),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final MachineCredential? machine = widget.activeMachine;
    if (machine == null) {
      return ListTile(
        leading: const Icon(Icons.lens, color: Colors.grey, size: 14),
        title: Text(context.l10n.notConnected),
        subtitle: Text(context.l10n.importOrChooseMachine),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: _isLoading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                Icons.lens,
                color: _isOnline
                    ? const Color(0xFF10B981)
                    : const Color(0xFFEF4444),
                size: 14,
              ),
        title: Text(
          machine.displayName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        subtitle: Text(
          _isLoading
              ? context.l10n.loadingStatus
              : (_isOnline ? context.l10n.online : context.l10n.offline),
          style: TextStyle(
            color: _isLoading
                ? Theme.of(context).colorScheme.outline
                : (_isOnline
                    ? const Color(0xFF10B981)
                    : const Color(0xFFEF4444)),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: _showStatusDialog,
      ),
    );
  }
}
