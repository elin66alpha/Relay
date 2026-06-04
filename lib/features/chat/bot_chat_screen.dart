// ignore_for_file: use_build_context_synchronously

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../core/backend/backend_client.dart';
import '../../core/models/agent_session.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/machine_credential.dart';
import '../../core/platform/file_saver.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/settings/app_settings_controller.dart';
import '../cli_agents/cli_agents_controller.dart';
import '../cli_agents/cli_agents_drawer.dart';
import '../machines/machine_credentials_controller.dart';
import 'agent_controls.dart';
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

class _BotChatScreenState extends State<BotChatScreen>
    with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  bool _autoScrollQueued = false;
  int _lastMessageCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.chatController.addListener(_onChatChanged);
    widget.agentsController.addListener(_onContextChanged);
    widget.machinesController.addListener(_onContextChanged);
    widget.settingsController.addListener(_onSettingsChanged);
    _syncContext();
    // Open straight at the latest message rather than the top of the list.
    _onChatChanged();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Coming back to the foreground, the OS may have torn down the long-lived
    // event SSE while the backend kept running a turn. Reconnect it right away
    // so a turn that continued in the background is mirrored without waiting for
    // the periodic reconnect.
    if (state == AppLifecycleState.resumed) {
      widget.chatController.reconnectEvents();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    // Register for Web Push so quota alerts arrive with the tab closed (web-only,
    // best-effort, runs once). Permission was already requested at startup.
    widget.chatController.syncPushSubscription();
    // Register for FCM on mobile. Missing Firebase config is a graceful no-op.
    widget.chatController.syncFcmRegistration();
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
      final int count = widget.chatController.messageCount;
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

  Future<void> _showHistorySearch() async {
    final ChatHistorySearchResult? result =
        await showDialog<ChatHistorySearchResult>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _HistorySearchDialog(chatController: widget.chatController),
    );
    if (result == null) return;
    try {
      await widget.chatController.selectSession(
        cliAgentByKey(result.agentKey),
        result.sessionId,
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.searchFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _exportMarkdown() async {
    try {
      final ConversationExport export =
          await widget.chatController.exportCurrentSessionMarkdown();
      final List<int> bytes = utf8.encode(export.markdown);
      final DownloadSaveResult saved = await saveDownloadStream(
        fileName: export.fileName,
        total: bytes.length,
        bytes: Stream<List<int>>.value(bytes),
        onProgress: (_, __) {},
      );
      if (!mounted) return;
      final String message = saved.isBrowserDownload
          ? context.l10n.savedToBrowserDownloads
          : context.l10n.savedTo(saved.path ?? export.fileName);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.exportFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
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
            widget.chatController,
          ]),
          builder: (BuildContext context, Widget? _) {
            final MachineCredential? machine =
                widget.machinesController.activeMachine;
            final AgentSession? session = widget.chatController.activeSession;
            final String subtitle = <String>[
              if (machine != null) machine.displayName,
              if (session != null) session.name,
            ].join(' - ');
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
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
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
                icon: const Icon(Icons.search_rounded),
                tooltip: context.l10n.searchChats,
                onPressed: widget.chatController.isThinking
                    ? null
                    : _showHistorySearch,
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
                  final List<ChatMessage> messages =
                      widget.chatController.messages;
                  return Column(
                    children: <Widget>[
                      if (widget.chatController.agentLoggedIn(agent.key) ==
                          false)
                        _NotLoggedInBanner(
                          agentLabel: agent.label,
                          onRecheck: widget.chatController.refreshAuthStatus,
                        ),
                      Expanded(
                        child: messages.isEmpty
                            ? _EmptyChatPlaceholder(agentName: agent.label)
                            : ListView.builder(
                                controller: _scroll,
                                padding:
                                    const EdgeInsets.fromLTRB(16, 12, 16, 18),
                                itemCount: messages.length,
                                itemBuilder: (BuildContext context, int index) {
                                  final ChatMessage message = messages[index];
                                  return _MessageBubble(
                                    key: ValueKey<String>(message.id),
                                    message: message,
                                    retryable: widget.chatController
                                        .isRetryable(message),
                                    streaming: widget.chatController
                                        .isStreaming(message),
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
                        backend: widget.chatController.backend,
                        agentKey: widget.agentsController.activeAgent.key,
                        isThinking: widget.chatController.isThinking,
                        isCancelling: widget.chatController.isCancelling,
                        onSend: _send,
                        onCancel: widget.chatController.cancelActiveTurn,
                        onClear: _confirmClearHistory,
                        onCompress: _sendCompact,
                        onExportMarkdown: _exportMarkdown,
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

class _HistorySearchDialog extends StatefulWidget {
  const _HistorySearchDialog({required this.chatController});

  final BotChatController chatController;

  @override
  State<_HistorySearchDialog> createState() => _HistorySearchDialogState();
}

class _HistorySearchDialogState extends State<_HistorySearchDialog> {
  final TextEditingController _query = TextEditingController();
  Future<List<ChatHistorySearchResult>>? _future;
  bool _currentAgentOnly = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search() {
    final String query = _query.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _future = widget.chatController.searchHistory(
        query,
        currentAgentOnly: _currentAgentOnly,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.searchChats),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _query,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: context.l10n.searchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _currentAgentOnly,
                title: Text(context.l10n.currentAgentOnly),
                onChanged: (bool value) {
                  setState(() {
                    _currentAgentOnly = value;
                  });
                  if (_future != null) _search();
                },
              ),
              SizedBox(
                height: 320,
                child: _HistorySearchResults(
                  future: _future,
                  onSelected: (ChatHistorySearchResult result) =>
                      Navigator.of(context).pop(result),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _search,
          child: Text(context.l10n.searchChats),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.close),
        ),
      ],
    );
  }
}

class _HistorySearchResults extends StatelessWidget {
  const _HistorySearchResults({
    required this.future,
    required this.onSelected,
  });

  final Future<List<ChatHistorySearchResult>>? future;
  final ValueChanged<ChatHistorySearchResult> onSelected;

  @override
  Widget build(BuildContext context) {
    if (future == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<List<ChatHistorySearchResult>>(
      future: future,
      builder: (
        BuildContext context,
        AsyncSnapshot<List<ChatHistorySearchResult>> snapshot,
      ) {
        final ColorScheme colors = Theme.of(context).colorScheme;
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Text(
            context.l10n.searchFailed(snapshot.error!),
            style: TextStyle(color: colors.error),
          );
        }
        final List<ChatHistorySearchResult> results =
            snapshot.data ?? const <ChatHistorySearchResult>[];
        if (results.isEmpty) {
          return Align(
            alignment: Alignment.topLeft,
            child: Text(
              context.l10n.noSearchResults,
              style: TextStyle(color: colors.outline),
            ),
          );
        }
        return ListView.separated(
          shrinkWrap: true,
          itemCount: results.length,
          separatorBuilder: (BuildContext context, int index) =>
              const Divider(height: 1),
          itemBuilder: (BuildContext context, int index) {
            final ChatHistorySearchResult result = results[index];
            final CliAgent agent = cliAgentByKey(result.agentKey);
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${agent.label} - ${result.sessionName}'),
              subtitle: Text(
                result.snippet,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onSelected(result),
            );
          },
        );
      },
    );
  }
}

class _InputBar extends StatefulWidget {
  const _InputBar({
    required this.controller,
    required this.backend,
    required this.agentKey,
    required this.isThinking,
    required this.isCancelling,
    required this.onSend,
    required this.onCancel,
    required this.onClear,
    required this.onCompress,
    required this.onExportMarkdown,
  });

  final TextEditingController controller;
  final BackendClient backend;
  final String agentKey;
  final bool isThinking;
  final bool isCancelling;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final VoidCallback onClear;
  final VoidCallback onCompress;
  final VoidCallback onExportMarkdown;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  final FocusNode _inputFocus = FocusNode();
  bool _actionsOpen = false;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
    _inputFocus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(_InputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      _hasText = widget.controller.text.trim().isNotEmpty;
      widget.controller.addListener(_onTextChanged);
    }
    if (widget.isThinking && _actionsOpen) {
      _actionsOpen = false;
    }
    // On web the text field loses focus once a reply finishes, forcing the user
    // to click back into it. Refocus when the turn ends. On mobile we leave
    // focus alone so we don't pop the soft keyboard open after every reply.
    if (kIsWeb && oldWidget.isThinking && !widget.isThinking) {
      _inputFocus.requestFocus();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _inputFocus.removeListener(_onFocusChanged);
    _inputFocus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final bool nextHasText = widget.controller.text.trim().isNotEmpty;
    if (nextHasText == _hasText && !(nextHasText && _actionsOpen)) return;
    setState(() {
      _hasText = nextHasText;
      if (nextHasText) _actionsOpen = false;
    });
  }

  void _onFocusChanged() {
    if (!_inputFocus.hasFocus || !_actionsOpen) return;
    setState(() => _actionsOpen = false);
  }

  void _toggleActions() {
    if (widget.isThinking || _hasText) return;
    _inputFocus.unfocus();
    setState(() => _actionsOpen = !_actionsOpen);
  }

  void _closeActions() {
    if (!_actionsOpen) return;
    setState(() => _actionsOpen = false);
  }

  void _sendText() {
    if (widget.isThinking || !_hasText) return;
    _closeActions();
    widget.onSend();
  }

  void _runAction(VoidCallback action) {
    _closeActions();
    action();
  }

  void _submitFromKeyboard() {
    if (!kIsWeb) return;
    _sendText();
  }

  @override
  Widget build(BuildContext context) {
    final bool canCancel = widget.isThinking && !widget.isCancelling;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget input = _MessageTextField(
      focusNode: _inputFocus,
      controller: widget.controller,
      enabled: !widget.isThinking,
      onTap: _closeActions,
    );
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
                          child: input,
                        )
                      : input,
                ),
                const SizedBox(width: 8),
                SizedBox.square(
                  dimension: 44,
                  child: IconButton.filledTonal(
                    onPressed: widget.isThinking
                        ? canCancel
                            ? widget.onCancel
                            : null
                        : _hasText
                            ? _sendText
                            : _toggleActions,
                    icon: Icon(
                      widget.isThinking
                          ? Icons.stop_rounded
                          : _hasText
                              ? Icons.arrow_upward_rounded
                              : Icons.add_rounded,
                    ),
                    tooltip: widget.isThinking
                        ? context.l10n.stop
                        : _hasText
                            ? context.l10n.send
                            : context.l10n.moreChatActions,
                  ),
                ),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: _actionsOpen
                  ? _ComposerActionPanel(
                      backend: widget.backend,
                      agentKey: widget.agentKey,
                      onOpenSettingsPage: _closeActions,
                      onClear: () => _runAction(widget.onClear),
                      onCompress: () => _runAction(widget.onCompress),
                      onExportMarkdown: () =>
                          _runAction(widget.onExportMarkdown),
                    )
                  : const SizedBox.shrink(),
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
    required this.onTap,
  });

  final FocusNode focusNode;
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return TextField(
      focusNode: focusNode,
      controller: controller,
      enabled: enabled,
      onTap: onTap,
      minLines: 1,
      maxLines: 6,
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        hintText: context.l10n.inputHint,
        filled: true,
        fillColor: colors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }
}

class _ComposerActionPanel extends StatelessWidget {
  const _ComposerActionPanel({
    required this.backend,
    required this.agentKey,
    required this.onOpenSettingsPage,
    required this.onClear,
    required this.onCompress,
    required this.onExportMarkdown,
  });

  final BackendClient backend;
  final String agentKey;
  final VoidCallback onOpenSettingsPage;
  final VoidCallback onClear;
  final VoidCallback onCompress;
  final VoidCallback onExportMarkdown;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AgentControlsButtons(
            backend: backend,
            agentKey: agentKey,
            onOpenPage: onOpenSettingsPage,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: <Widget>[
              ComposerActionButton(
                icon: Icons.refresh_rounded,
                label: context.l10n.clearChat,
                onPressed: onClear,
              ),
              ComposerActionButton(
                icon: Icons.compress,
                label: context.l10n.compress,
                onPressed: onCompress,
              ),
              ComposerActionButton(
                icon: Icons.download_outlined,
                label: context.l10n.exportMarkdown,
                onPressed: onExportMarkdown,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.retryable,
    required this.streaming,
    required this.awaitingFirstToken,
    required this.errorDetail,
    required this.system,
    required this.cancelled,
    required this.progressLines,
    required this.onRetry,
    super.key,
  });

  final ChatMessage message;
  final bool retryable;
  final bool streaming;
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
                    formatInlineEmphasis: !isUser && !streaming,
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
    strong: base.copyWith(fontWeight: FontWeight.w700),
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
    code: base.copyWith(fontStyle: FontStyle.italic),
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
