// ignore_for_file: use_build_context_synchronously

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../core/backend/backend_client.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/machine_credential.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/settings/app_settings_controller.dart';
import '../cli_agents/cli_agents_controller.dart';
import '../cli_agents/cli_agents_drawer.dart';
import '../machines/machine_credentials_controller.dart';
import 'bot_chat_controller.dart';

class BotChatScreen extends StatefulWidget {
  const BotChatScreen({
    required this.agentsController,
    required this.chatController,
    required this.machinesController,
    required this.settingsController,
    super.key,
  });

  final CliAgentsController agentsController;
  final BotChatController chatController;
  final MachineCredentialsController machinesController;
  final AppSettingsController settingsController;

  @override
  State<BotChatScreen> createState() => _BotChatScreenState();
}

class _BotChatScreenState extends State<BotChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  bool _autoScrollQueued = false;
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    widget.chatController.addListener(_onChatChanged);
    widget.agentsController.addListener(_onContextChanged);
    widget.machinesController.addListener(_onContextChanged);
    widget.settingsController.addListener(_onSettingsChanged);
    _syncContext();
    // Open straight at the latest message rather than the top of the list.
    _onChatChanged();
  }

  @override
  void dispose() {
    widget.chatController.removeListener(_onChatChanged);
    widget.agentsController.removeListener(_onContextChanged);
    widget.machinesController.removeListener(_onContextChanged);
    widget.settingsController.removeListener(_onSettingsChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onContextChanged() {
    _syncContext();
  }

  void _onSettingsChanged() {
    widget.chatController.setLanguage(widget.settingsController.language);
  }

  void _syncContext() {
    widget.chatController.setLanguage(widget.settingsController.language);
    final CliAgent active = widget.agentsController.activeAgent;
    final MachineCredential? machine = widget.machinesController.activeMachine;
    if (machine == null) return;
    final bool hadMachine = widget.chatController.machine != null;
    final bool machineChanged = widget.chatController.machine?.id != machine.id;
    if (widget.chatController.agent.key != active.key || machineChanged) {
      widget.chatController.loadFor(active, machine);
    }
    if (hadMachine && machineChanged) {
      widget.chatController.reconnectEvents();
    } else {
      widget.chatController.connectEvents();
    }
  }

  Future<void> _send() async {
    final String text = _input.text;
    _input.clear();
    await widget.chatController.sendUserText(text);
  }

  Future<void> _sendCompact() async {
    try {
      await widget.chatController.compressConversation();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: Text(context.l10n.compressComplete),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(context.l10n.ok),
            ),
          ],
        ),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.compressFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  // A streaming reply notifies many times per second. Calling animateTo on each
  // notification restarts the animation every frame, which is the main source
  // of scroll jank (and it gets worse as the list grows). Instead, coalesce to
  // at most one scroll per frame, jump rather than animate so nothing competes,
  // and leave the user alone when they have scrolled up to read older messages.
  void _onChatChanged() {
    if (_autoScrollQueued) return;
    _autoScrollQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoScrollQueued = false;
      if (!_scroll.hasClients) return;
      final ScrollPosition pos = _scroll.position;
      final int count = widget.chatController.messages.length;
      final bool messageAdded = count != _lastMessageCount;
      _lastMessageCount = count;
      final bool nearBottom = pos.maxScrollExtent - pos.pixels < 280;
      // Follow streaming text only while pinned to the bottom; always snap when
      // a new message (user send / new reply bubble) is appended.
      if (!nearBottom && !messageAdded) return;
      _scroll.jumpTo(pos.maxScrollExtent);
    });
  }

  Future<void> _confirmClearHistory() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.l10n.clearChatTitle),
        content: Text(context.l10n.clearChatBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.clear),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.chatController.clearHistory();
    }
  }

  Future<void> _showUsageDialog() async {
    final Future<UsageReport> usageFuture = widget.chatController.usageReport();
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(context.l10n.usageTitle),
          content: SizedBox(
            width: 420,
            child: FutureBuilder<UsageReport>(
              future: usageFuture,
              builder:
                  (BuildContext context, AsyncSnapshot<UsageReport> snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return Text(context.l10n.loadingUsage);
                }
                if (snapshot.hasError) {
                  return Text(
                    snapshot.error.toString(),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  );
                }
                final UsageReport report = snapshot.data!;
                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (final UsageAgent agent in report.agents)
                        _UsageAgentPanel(agent: agent),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(context.l10n.close),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool usePermanentSidebar = MediaQuery.sizeOf(context).width >= 900;
    final Widget sidebar = CliAgentsDrawer(
      agentsController: widget.agentsController,
      chatController: widget.chatController,
      machinesController: widget.machinesController,
      settingsController: widget.settingsController,
      closeOnAction: !usePermanentSidebar,
    );
    return Scaffold(
      drawerScrimColor: Colors.black54,
      drawer: usePermanentSidebar
          ? null
          : Drawer(
              child: SafeArea(child: sidebar),
            ),
      appBar: AppBar(
        leading: usePermanentSidebar
            ? null
            : Builder(
                builder: (BuildContext context) {
                  return IconButton(
                    icon: const Icon(Icons.menu),
                    tooltip: context.l10n.menu,
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  );
                },
              ),
        title: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            widget.agentsController,
            widget.machinesController,
          ]),
          builder: (BuildContext context, Widget? _) {
            final MachineCredential? machine =
                widget.machinesController.activeMachine;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  widget.agentsController.activeAgent.label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (machine != null)
                  Text(
                    machine.displayName,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      fontSize: 12,
                    ),
                  ),
              ],
            );
          },
        ),
        actions: <Widget>[
          AnimatedBuilder(
            animation: widget.chatController,
            builder: (BuildContext context, Widget? _) {
              return IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: context.l10n.clearChat,
                onPressed: widget.chatController.isThinking
                    ? null
                    : _confirmClearHistory,
              );
            },
          ),
          AnimatedBuilder(
            animation: widget.chatController,
            builder: (BuildContext context, Widget? _) {
              return IconButton(
                icon: const Icon(Icons.compress),
                tooltip: context.l10n.compress,
                onPressed:
                    widget.chatController.isThinking ? null : _sendCompact,
              );
            },
          ),
          AnimatedBuilder(
            animation: widget.chatController,
            builder: (BuildContext context, Widget? _) {
              return IconButton(
                icon: const Icon(Icons.query_stats_outlined),
                tooltip: context.l10n.usage,
                onPressed:
                    widget.chatController.isThinking ? null : _showUsageDialog,
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Row(
          children: <Widget>[
            if (usePermanentSidebar)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  border: Border(
                    right: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: SizedBox(width: 320, child: sidebar),
              ),
            Expanded(
              child: AnimatedBuilder(
                animation: Listenable.merge(<Listenable>[
                  widget.agentsController,
                  widget.machinesController,
                  widget.chatController,
                ]),
                builder: (BuildContext context, Widget? _) {
                  final CliAgent agent = widget.agentsController.activeAgent;
                  return Column(
                    children: <Widget>[
                      if (widget.chatController.agentLoggedIn(agent.key) ==
                          false)
                        _NotLoggedInBanner(
                          agentLabel: agent.label,
                          onRecheck: widget.chatController.refreshAuthStatus,
                        ),
                      Expanded(
                        child: widget.chatController.messages.isEmpty
                            ? _EmptyChatPlaceholder(agentName: agent.label)
                            : ListView.builder(
                                controller: _scroll,
                                padding:
                                    const EdgeInsets.fromLTRB(16, 12, 16, 18),
                                itemCount:
                                    widget.chatController.messages.length,
                                itemBuilder: (BuildContext context, int index) {
                                  final ChatMessage message =
                                      widget.chatController.messages[index];
                                  return _MessageBubble(
                                    message: message,
                                    retryable: widget.chatController
                                        .isRetryable(message),
                                    awaitingFirstToken: widget.chatController
                                        .isAwaitingFirstToken(message),
                                    errorDetail: widget.chatController
                                        .errorDetailFor(message),
                                    system: widget.chatController
                                        .isSystemMessage(message),
                                    cancelled: widget.chatController
                                        .isCancelled(message),
                                    progressLines: widget.chatController
                                        .progressLinesFor(message),
                                    onRetry: () =>
                                        widget.chatController.retry(message),
                                  );
                                },
                              ),
                      ),
                      _InputBar(
                        controller: _input,
                        isThinking: widget.chatController.isThinking,
                        isCancelling: widget.chatController.isCancelling,
                        onSend: _send,
                        onCancel: widget.chatController.cancelActiveTurn,
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotLoggedInBanner extends StatelessWidget {
  const _NotLoggedInBanner({
    required this.agentLabel,
    required this.onRecheck,
  });

  final String agentLabel;
  final Future<void> Function() onRecheck;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.lock_outline_rounded,
              size: 18,
              color: colors.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.l10n.agentNotLoggedInBanner(agentLabel),
                style: TextStyle(
                  color: colors.onErrorContainer,
                  fontSize: 13,
                ),
              ),
            ),
            TextButton(
              onPressed: () => onRecheck(),
              child: Text(context.l10n.recheck),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChatPlaceholder extends StatelessWidget {
  const _EmptyChatPlaceholder({required this.agentName});

  final String agentName;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        context.l10n.startChat(agentName),
        style: TextStyle(
          color: Theme.of(context).colorScheme.outline,
          fontSize: 14,
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
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
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
                    fontSize: 15,
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
          const SizedBox(height: 10),
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

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String label = switch (quota.key) {
      'five_hour' => context.l10n.fiveHourQuota,
      'seven_day' => context.l10n.weeklyQuota,
      _ => quota.label,
    };
    final String percent = quota.remainingPercent == null
        ? context.l10n.unknown
        : '${quota.remainingPercent!.round()}%';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('$percent ${context.l10n.remaining}'),
                const SizedBox(height: 2),
                Text(
                  '${context.l10n.refreshAt}: ${_formatUsageTime(context, quota.resetsAt)}',
                  style: TextStyle(color: colors.outline, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _formatUsageTime(BuildContext context, String? iso) {
  if (iso == null || iso.isEmpty) return context.l10n.unknown;
  final DateTime? parsed = DateTime.tryParse(iso);
  if (parsed == null) return context.l10n.unknown;
  final DateTime local = parsed.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.month)}/${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

class _InputBar extends StatefulWidget {
  const _InputBar({
    required this.controller,
    required this.isThinking,
    required this.isCancelling,
    required this.onSend,
    required this.onCancel,
  });

  final TextEditingController controller;
  final bool isThinking;
  final bool isCancelling;
  final VoidCallback onSend;
  final VoidCallback onCancel;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  final FocusNode _inputFocus = FocusNode();

  @override
  void didUpdateWidget(_InputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // On web the text field loses focus once a reply finishes, forcing the user
    // to click back into it. Refocus when the turn ends. On mobile we leave
    // focus alone so we don't pop the soft keyboard open after every reply.
    if (kIsWeb && oldWidget.isThinking && !widget.isThinking) {
      _inputFocus.requestFocus();
    }
  }

  @override
  void dispose() {
    _inputFocus.dispose();
    super.dispose();
  }

  void _submitFromKeyboard() {
    if (!kIsWeb) return;
    if (!widget.isThinking) {
      widget.onSend();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool canSend = !widget.isThinking;
    final bool canCancel = widget.isThinking && !widget.isCancelling;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: kIsWeb
                      ? CallbackShortcuts(
                          bindings: <ShortcutActivator, VoidCallback>{
                            const SingleActivator(LogicalKeyboardKey.enter):
                                _submitFromKeyboard,
                          },
                          child: _MessageTextField(
                            focusNode: _inputFocus,
                            controller: widget.controller,
                            enabled: canSend,
                          ),
                        )
                      : _MessageTextField(
                          focusNode: _inputFocus,
                          controller: widget.controller,
                          enabled: canSend,
                        ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: widget.isThinking
                      ? canCancel
                          ? widget.onCancel
                          : null
                      : canSend
                          ? widget.onSend
                          : null,
                  icon: Icon(
                    widget.isThinking
                        ? Icons.stop_rounded
                        : Icons.arrow_upward_rounded,
                  ),
                  tooltip:
                      widget.isThinking ? context.l10n.stop : context.l10n.send,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageTextField extends StatelessWidget {
  const _MessageTextField({
    required this.focusNode,
    required this.controller,
    required this.enabled,
  });

  final FocusNode focusNode;
  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      focusNode: focusNode,
      controller: controller,
      enabled: enabled,
      minLines: 1,
      maxLines: 6,
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        hintText: context.l10n.inputHint,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.retryable,
    required this.awaitingFirstToken,
    required this.errorDetail,
    required this.system,
    required this.cancelled,
    required this.progressLines,
    required this.onRetry,
  });

  final ChatMessage message;
  final bool retryable;
  final bool awaitingFirstToken;
  final String? errorDetail;
  final bool system;
  final bool cancelled;
  final List<String> progressLines;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final bool isUser = message.isUser;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color bubbleColor = system
        ? colors.tertiaryContainer
        : isUser
            ? colors.primary
            : colors.surfaceContainerHighest;
    final Color textColor =
        isUser && !system ? colors.onPrimary : colors.onSurface;
    final Border? border = isUser && !system
        ? null
        : Border.all(
            color: colors.outlineVariant,
          );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.80,
            ),
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(12),
              border: border,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (awaitingFirstToken && message.content.isEmpty)
                  _TypingDots(color: textColor)
                else if (message.content.isNotEmpty)
                  _MessageText(
                    text: message.content,
                    color: textColor,
                    formatInlineEmphasis: !isUser,
                  ),
                if (progressLines.isNotEmpty) ...<Widget>[
                  if (message.content.isNotEmpty) const SizedBox(height: 8),
                  _ProgressLines(
                    lines: progressLines,
                    color: textColor,
                  ),
                ],
                if (cancelled) ...<Widget>[
                  if (message.content.isNotEmpty || progressLines.isNotEmpty)
                    const SizedBox(height: 8),
                  _MessageStatus(
                    icon: Icons.stop_circle_outlined,
                    text: context.l10n.cancelled,
                    color: textColor,
                  ),
                ],
              ],
            ),
          ),
          if (retryable) ...<Widget>[
            if (errorDetail != null && errorDetail!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  errorDetail!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 1, bottom: 4),
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: Text(context.l10n.retry),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MessageText extends StatelessWidget {
  const _MessageText({
    required this.text,
    required this.color,
    required this.formatInlineEmphasis,
  });

  final String text;
  final Color color;
  final bool formatInlineEmphasis;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = TextStyle(
      color: color,
      height: 1.45,
      fontSize: 15,
    );
    if (!formatInlineEmphasis) {
      return SelectableText(text, style: style);
    }
    return MarkdownBody(
      data: _normalizeAgentMarkdown(text),
      selectable: true,
      softLineBreak: true,
      styleSheet: _markdownStyleSheet(context, color, style),
    );
  }
}

MarkdownStyleSheet _markdownStyleSheet(
  BuildContext context,
  Color color,
  TextStyle base,
) {
  final ColorScheme colors = Theme.of(context).colorScheme;
  final Color codeBackground = colors.surface.withValues(alpha: 0.55);
  final Color borderColor = color.withValues(alpha: 0.20);
  return MarkdownStyleSheet(
    p: base,
    pPadding: EdgeInsets.zero,
    strong: base.copyWith(fontStyle: FontStyle.italic),
    em: base.copyWith(fontStyle: FontStyle.italic),
    h1: base.copyWith(
      fontSize: 21,
      fontWeight: FontWeight.w800,
      height: 1.25,
    ),
    h1Padding: const EdgeInsets.only(top: 4, bottom: 6),
    h2: base.copyWith(
      fontSize: 19,
      fontWeight: FontWeight.w800,
      height: 1.28,
    ),
    h2Padding: const EdgeInsets.only(top: 4, bottom: 5),
    h3: base.copyWith(
      fontSize: 17,
      fontWeight: FontWeight.w700,
      height: 1.30,
    ),
    h3Padding: const EdgeInsets.only(top: 3, bottom: 4),
    h4: base.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
    h4Padding: const EdgeInsets.only(top: 3, bottom: 3),
    h5: base.copyWith(fontWeight: FontWeight.w700),
    h5Padding: const EdgeInsets.only(top: 2, bottom: 2),
    h6: base.copyWith(fontWeight: FontWeight.w700),
    h6Padding: const EdgeInsets.only(top: 2, bottom: 2),
    blockSpacing: 8,
    listIndent: 22,
    listBullet: base,
    code: base.copyWith(
      fontFamily: 'monospace',
      fontSize: 14,
      backgroundColor: codeBackground,
    ),
    codeblockPadding: const EdgeInsets.all(9),
    codeblockDecoration: BoxDecoration(
      color: codeBackground,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: borderColor),
    ),
    blockquote: base.copyWith(color: color.withValues(alpha: 0.78)),
    blockquotePadding: const EdgeInsets.only(left: 10),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          color: color.withValues(alpha: 0.45),
          width: 3,
        ),
      ),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: borderColor)),
    ),
  );
}

String _normalizeAgentMarkdown(String raw) {
  final List<String> output = <String>[];
  bool inFence = false;
  String? fenceMarker;
  for (final String line in raw.split('\n')) {
    final String trimmed = line.trimLeft();
    final String? marker = trimmed.startsWith('```')
        ? '```'
        : trimmed.startsWith('~~~')
            ? '~~~'
            : null;
    if (marker != null) {
      if (!inFence) {
        inFence = true;
        fenceMarker = marker;
      } else if (fenceMarker == marker) {
        inFence = false;
        fenceMarker = null;
      }
      output.add(line);
      continue;
    }
    output.add(inFence ? line : _normalizeMarkdownLine(line));
  }
  return output.join('\n');
}

String _normalizeMarkdownLine(String line) {
  final RegExpMatch? heading =
      RegExp(r'^( {0,3})(#{1,6})(?!#)\s*(.*?)\s*#*\s*$').firstMatch(line);
  if (heading != null) {
    final String content = (heading.group(3) ?? '').trim();
    if (content.isNotEmpty) {
      return '${heading.group(1)}${heading.group(2)} $content';
    }
  }

  String value = line.replaceAllMapped(
    RegExp(r'##([^#\n]+?)##'),
    (Match match) => '*${match.group(1)}*',
  );

  final RegExpMatch? boldPrefix =
      RegExp(r'^(\s*)\*\*\s*(\S.*)$').firstMatch(value);
  if (boldPrefix == null) return value;
  final String leadingWhitespace = boldPrefix.group(1) ?? '';
  final int contentStart = leadingWhitespace.length + 2;
  if (value.indexOf('**', contentStart) != -1) return value;
  value = '$leadingWhitespace**${boldPrefix.group(2)}**';
  return value;
}

class _ProgressLines extends StatelessWidget {
  const _ProgressLines({
    required this.lines,
    required this.color,
  });

  final List<String> lines;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final String line in lines)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    line,
                    style: TextStyle(
                      color: color.withValues(alpha: 0.72),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MessageStatus extends StatelessWidget {
  const _MessageStatus({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          icon,
          size: 14,
          color: color.withValues(alpha: 0.68),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            color: color.withValues(alpha: 0.72),
            fontSize: 12,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});

  final Color color;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double _opacity(double t, int i) {
    final double offset = i * 0.18;
    final double phase = (t - offset) % 1.0;
    final double wrapped = phase < 0 ? phase + 1.0 : phase;
    if (wrapped < 0.5) return 0.35 + 0.65 * (wrapped * 2);
    return 0.35 + 0.65 * ((1.0 - wrapped) * 2);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (BuildContext context, Widget? _) {
          final double t = _ctrl.value;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List<Widget>.generate(3, (int i) {
              return Padding(
                padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
                child: Opacity(
                  opacity: _opacity(t, i),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: widget.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
