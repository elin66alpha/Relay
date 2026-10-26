// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/models/agent_session.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/cli_agent.dart';
import '../../core/models/machine_credential.dart';
import '../../core/platform/file_saver.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/settings/wallpaper.dart';
import '../../core/widgets/agent_icon.dart';
import '../../core/widgets/chat_wallpaper.dart';
import '../cli_agents/agent_status_lights.dart';
import '../cli_agents/cli_agents_controller.dart';
import '../machines/machine_credentials_controller.dart';
import '../quota/quota_strip.dart';
import 'bot_chat_controller.dart';
import 'bot_message_bubble.dart';
import 'chat_input_bar.dart';
import 'cli_agents_drawer.dart';
import 'context_meter.dart';
import 'history_search_dialog.dart';
import 'home_navigation_page.dart';

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
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  bool _autoScrollQueued = false;
  int _lastMessageCount = 0;
  bool _agentsSynced = false;
  bool _agentsRefreshing = false;
  late (AppLanguage, bool, bool) _lastNotificationSettings;

  (AppLanguage, bool, bool) get _notificationSettings => (
        widget.settingsController.language,
        widget.settingsController.quotaPushEnabled,
        widget.settingsController.taskPushEnabled,
      );

  // "Search chats" jump: the picked hit's message is scrolled into view, then
  // flashed with the matched term marked inside it for a moment. The anchor key
  // is what the scroll targets once the row is actually built.
  String? _highlightMessageId;
  String? _highlightQuery;
  GlobalKey? _highlightAnchor;
  Timer? _highlightTimer;
  bool _revealingMatch = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastNotificationSettings = _notificationSettings;
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
    _highlightTimer?.cancel();
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onContextChanged() {
    _syncContext();
  }

  Future<void> _refreshAgents() async {
    // Rapid context syncs can call this before the first fetch resolves; one
    // in-flight request at a time is enough.
    if (_agentsRefreshing) return;
    _agentsRefreshing = true;
    try {
      final List<CliAgent> agents =
          await widget.chatController.backend.fetchAgents();
      if (!mounted) return;
      widget.agentsController.syncAgents(agents);
      _agentsSynced = true;
    } catch (_) {
      // Best-effort: keep the built-in list and retry on the next context sync.
    } finally {
      _agentsRefreshing = false;
    }
  }

  void _onSettingsChanged() {
    final (AppLanguage, bool, bool) next = _notificationSettings;
    if (next == _lastNotificationSettings) return;
    _lastNotificationSettings = next;
    widget.chatController.setLanguage(widget.settingsController.language);
    widget.chatController.setNotificationPreferences(
      quotaPushEnabled: widget.settingsController.quotaPushEnabled,
      taskPushEnabled: widget.settingsController.taskPushEnabled,
    );
    widget.chatController.syncPushSubscription(force: true);
    widget.chatController.syncFcmRegistration(force: true);
  }

  void _syncContext() {
    widget.chatController.setLanguage(widget.settingsController.language);
    widget.chatController.setNotificationPreferences(
      quotaPushEnabled: widget.settingsController.quotaPushEnabled,
      taskPushEnabled: widget.settingsController.taskPushEnabled,
    );
    final CliAgent active = widget.agentsController.activeAgent;
    final MachineCredential? machine = widget.machinesController.activeMachine;
    if (machine == null) return;
    // Pull the host's live agent list and install/auth status. Retries until it
    // lands.
    if (!_agentsSynced) unawaited(_refreshAgents());
    if (!isCliAgentSelectable(active)) {
      if (widget.chatController.machine != null) {
        widget.chatController.goHome();
      }
      return;
    }
    if (widget.chatController.machine == null) return;
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
    final String compactedNotice = context.l10n.conversationCompacted;
    try {
      await widget.chatController.compressConversation();
      widget.chatController.appendNotice(compactedNotice);
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
  //
  // The list is reverse:true, so the bottom (newest message) is offset 0
  // (minScrollExtent) and scrolling up to older messages increases the offset.
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
      // A search jump is driving the scroll position; don't yank it back down
      // to the newest message while it walks toward the match.
      if (_revealingMatch) return;
      final bool nearBottom = pos.pixels - pos.minScrollExtent < 280;
      // Follow streaming text only while pinned to the bottom; always snap when
      // a new message (user send / new reply bubble) is appended.
      if (!nearBottom && !messageAdded) return;
      _scroll.jumpTo(pos.minScrollExtent);
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
    final ({ChatHistorySearchResult hit, String query})? picked =
        await showDialog<({ChatHistorySearchResult hit, String query})>(
      context: context,
      builder: (BuildContext dialogContext) =>
          HistorySearchDialog(chatController: widget.chatController),
    );
    if (picked == null || !mounted) return;
    final ChatHistorySearchResult result = picked.hit;
    final MachineCredential? machine = widget.machinesController.activeMachine;
    if (machine == null) return;
    final CliAgent agent = cliAgentByKey(result.agentKey);
    try {
      // A hit can live under another agent, so move the whole UI across, not
      // just the chat controller: otherwise the next context sync sees the
      // agents controller still pointing at the old agent and loads it back.
      if (!await widget.agentsController.setActive(agent.key)) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(agentUnavailableMessage(context.l10n, agent))),
        );
        return;
      }
      await widget.chatController.loadFor(agent, machine);
      await widget.chatController.selectSession(agent, result.sessionId);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.searchFailed(err)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }
    if (!mounted) return;
    await _revealSearchMatch(result.messageId, picked.query);
  }

  /// Scrolls the now-loaded conversation to the matched message and flashes it,
  /// with the search term marked inside the bubble, for a couple of seconds.
  Future<void> _revealSearchMatch(String messageId, String query) async {
    final List<ChatMessage> messages = widget.chatController.messages;
    final int index = messages.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );
    if (index < 0) return;
    _highlightTimer?.cancel();
    final GlobalKey anchor = GlobalKey();
    setState(() {
      _highlightMessageId = messageId;
      _highlightQuery = query;
      _highlightAnchor = anchor;
      _revealingMatch = true;
    });
    // The list is reverse:true, so row 0 is the newest message.
    await _scrollToRow(messages.length - 1 - index, messages.length, anchor);
    if (!mounted) return;
    _revealingMatch = false;
    _highlightTimer = Timer(const Duration(milliseconds: 2600), () {
      if (!mounted) return;
      setState(() {
        _highlightMessageId = null;
        _highlightQuery = null;
        _highlightAnchor = null;
      });
    });
  }

  // The message list builds lazily, so the target row is usually not mounted
  // yet and there is nothing to ensureVisible on. Walk toward it using the
  // position's own average-extent estimate, which sharpens as more rows are
  // built, then hand off to ensureVisible once the row exists.
  Future<void> _scrollToRow(int row, int rowCount, GlobalKey anchor) async {
    for (int attempt = 0; attempt < 24; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scroll.hasClients) return;
      final BuildContext? anchored = anchor.currentContext;
      if (anchored != null) {
        await Scrollable.ensureVisible(
          anchored,
          alignment: 0.5,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      final ScrollPosition pos = _scroll.position;
      final double average =
          (pos.maxScrollExtent + pos.viewportDimension) / rowCount;
      final double target = (row * average).clamp(
        pos.minScrollExtent,
        pos.maxScrollExtent,
      );
      if ((target - pos.pixels).abs() < 1) return;
      _scroll.jumpTo(target);
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
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
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.agentsController,
        widget.settingsController,
      ]),
      builder: (BuildContext context, Widget? _) => _buildChat(context),
    );
  }

  Widget _buildChat(BuildContext context) {
    final bool usePermanentSidebar = MediaQuery.sizeOf(context).width >= 900;
    final Wallpaper wallpaper = widget.settingsController.wallpaper;
    final bool acrylic = wallpaper.bytes != null;
    final Widget sidebar = CliAgentsDrawer(
      agentsController: widget.agentsController,
      chatController: widget.chatController,
      machinesController: widget.machinesController,
      settingsController: widget.settingsController,
      closeOnAction: !usePermanentSidebar,
    );
    return ChatWallpaper(
      wallpaper: wallpaper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        drawerScrimColor: Colors.black54,
        // Let mobile users open the drawer from anywhere in the chat.
        drawerEdgeDragWidth: !kIsWeb &&
                (defaultTargetPlatform == TargetPlatform.android ||
                    defaultTargetPlatform == TargetPlatform.iOS)
            ? MediaQuery.sizeOf(context).width
            : null,
        drawer: usePermanentSidebar
            ? null
            : Drawer(
                backgroundColor: acrylic ? Colors.transparent : null,
                surfaceTintColor: acrylic ? Colors.transparent : null,
                // The drawer covers the chat and its scrim, so it blurs a
                // backdrop of its own rather than the page's shared one.
                child: BackdropGroup(
                  child: ChatChromeSurface(
                    acrylic: acrylic,
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    border: Border(
                      right: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: SafeArea(child: sidebar),
                  ),
                ),
              ),
        appBar: usePermanentSidebar
            ? null
            : AppBar(
                backgroundColor: acrylic ? Colors.transparent : null,
                surfaceTintColor: acrylic ? Colors.transparent : null,
                flexibleSpace: acrylic ? const AcrylicAppBarBackground() : null,
                leading: Builder(
                  builder: (BuildContext context) {
                    return IconButton(
                      icon: const Icon(Icons.menu),
                      tooltip: context.l10n.menu,
                      onPressed: () => Scaffold.of(context).openDrawer(),
                    );
                  },
                ),
                title: _ChatTitle(
                  agentsController: widget.agentsController,
                  chatController: widget.chatController,
                ),
                actions: <Widget>[
                  _SearchButton(
                    chatController: widget.chatController,
                    onPressed: _showHistorySearch,
                  ),
                ],
              ),
        // The bottom inset is padded inside the composer and sidebar so their
        // surfaces reach the screen edge behind the gesture bar.
        body: SafeArea(
          bottom: false,
          child: Row(
            children: <Widget>[
              if (usePermanentSidebar)
                ChatChromeSurface(
                  acrylic: acrylic,
                  color: Theme.of(context).colorScheme.surfaceContainer,
                  border: Border(
                    right: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  child: SizedBox(width: 320, child: SafeArea(child: sidebar)),
                ),
              Expanded(
                child: Column(
                  children: <Widget>[
                    if (usePermanentSidebar)
                      _DesktopChatHeader(
                        acrylic: acrylic,
                        agentsController: widget.agentsController,
                        chatController: widget.chatController,
                        onSearch: _showHistorySearch,
                      ),
                    ListenableBuilder(
                      listenable: Listenable.merge(<Listenable>[
                        widget.agentsController,
                        widget.chatController,
                      ]),
                      builder: (BuildContext context, Widget? _) {
                        if (widget.chatController.machine == null) {
                          return const SizedBox.shrink();
                        }
                        final CliAgent agent =
                            widget.agentsController.activeAgent;
                        // OAuth agents prompt to log in. hermes/opencode manage
                        // their key on the host, so they never show this banner.
                        if (agent.authKind != 'oauth' ||
                            widget.chatController.agentLoggedIn(agent.key) !=
                                false) {
                          return const SizedBox.shrink();
                        }
                        return _NotLoggedInBanner(
                          agentLabel: agent.label,
                          onRecheck: () =>
                              widget.chatController.refreshAuthStatus(
                            verifyCredentials: true,
                          ),
                        );
                      },
                    ),
                    Expanded(
                      child: ListenableBuilder(
                        listenable: Listenable.merge(<Listenable>[
                          widget.agentsController,
                          widget.chatController,
                        ]),
                        builder: (BuildContext context, Widget? _) {
                          if (widget.chatController.machine == null) {
                            return HomeNavigationPage(
                              agentsController: widget.agentsController,
                              chatController: widget.chatController,
                              machinesController: widget.machinesController,
                            );
                          }
                          final CliAgent agent =
                              widget.agentsController.activeAgent;
                          final List<ChatMessage> messages =
                              widget.chatController.messages;
                          if (widget.chatController.isHistoryLoading &&
                              messages.isEmpty) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          if (messages.isEmpty) {
                            // A wallpaper is the empty state; keep it clear.
                            if (acrylic) return const SizedBox.shrink();
                            return _EmptyChatPlaceholder(
                              agentKey: agent.key,
                              agentName: agent.label,
                            );
                          }
                          // SelectionArea keeps bubble text selectable/copyable
                          // without each bubble building its own overlay-based
                          // SelectableText (see MessageText), which crashed on
                          // conversation teardown.
                          return SelectionArea(
                            child: ListView.builder(
                              controller: _scroll,
                              // Reversed: offset 0 is the bottom, so opening or
                              // switching a conversation lands on the newest message
                              // instantly with no top-to-bottom jump.
                              reverse: true,
                              padding:
                                  const EdgeInsets.fromLTRB(12, 12, 12, 18),
                              itemCount: messages.length,
                              itemBuilder: (BuildContext context, int index) {
                                final ChatMessage message =
                                    messages[messages.length - 1 - index];
                                if (widget.chatController.isNoticeMessage(
                                  message,
                                )) {
                                  return ChatNotice(text: message.content);
                                }
                                final bool highlighted =
                                    message.id == _highlightMessageId;
                                final Widget bubble = BotMessageBubble(
                                  message: message,
                                  agentKey: agent.key,
                                  agentLabel: agent.label,
                                  highlightQuery:
                                      highlighted ? _highlightQuery : null,
                                  retryable: widget.chatController.isRetryable(
                                    message,
                                  ),
                                  streaming: widget.chatController.isStreaming(
                                    message,
                                  ),
                                  awaitingFirstToken: widget.chatController
                                      .isAwaitingFirstToken(message),
                                  errorDetail: widget.chatController
                                      .errorDetailFor(message),
                                  system: widget.chatController.isSystemMessage(
                                    message,
                                  ),
                                  cancelled: widget.chatController.isCancelled(
                                    message,
                                  ),
                                  queued:
                                      widget.chatController.isQueued(message),
                                  progressLines: widget.chatController
                                      .progressLinesFor(message),
                                  onRetry: () =>
                                      widget.chatController.retry(message),
                                  onEdit: () {
                                    _input.value = TextEditingValue(
                                      text: message.content,
                                      selection: TextSelection.collapsed(
                                        offset: message.content.length,
                                      ),
                                    );
                                    _inputFocus.requestFocus();
                                  },
                                  onCancelQueued: () => widget.chatController
                                      .cancelQueued(message),
                                  onOptionSelected: (String option) => widget
                                      .chatController
                                      .sendUserText(option),
                                );
                                // RepaintBoundary isolates each bubble's painting so
                                // a streaming bubble does not repaint the visible
                                // history every frame.
                                return RepaintBoundary(
                                  key: ValueKey<String>(message.id),
                                  child: highlighted
                                      ? SearchMatchFlash(
                                          key: _highlightAnchor,
                                          child: bubble,
                                        )
                                      : bubble,
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                    ListenableBuilder(
                      listenable: Listenable.merge(<Listenable>[
                        widget.agentsController,
                        widget.chatController,
                      ]),
                      builder: (BuildContext context, Widget? _) {
                        if (widget.chatController.machine == null) {
                          return const SafeArea(child: SizedBox.shrink());
                        }
                        final String agentKey =
                            widget.agentsController.activeAgent.key;
                        final bool showQuota = quotaStripSupports(agentKey);
                        final ({int? used, int? size}) contextUsage =
                            contextMeterUsage(
                          widget.chatController.messages,
                          contextWindow: widget.chatController.contextWindow,
                        );
                        return ChatInputBar(
                          acrylic: acrylic,
                          controller: _input,
                          focusNode: _inputFocus,
                          header: Row(
                            children: <Widget>[
                              Expanded(
                                child: showQuota
                                    ? QuotaStrip(
                                        quotaController: widget
                                            .chatController.quotaController,
                                        agentKey: agentKey,
                                        busy: widget.chatController.isThinking,
                                      )
                                    : const SizedBox.shrink(),
                              ),
                              if (contextMeterSupports(agentKey))
                                ContextMeter(usage: contextUsage),
                            ],
                          ),
                          backend: widget.chatController.backend,
                          agentKey: widget.agentsController.activeAgent.key,
                          sessionId: widget.chatController.activeSessionIdFor(
                            widget.agentsController.activeAgent.key,
                          ),
                          isThinking: widget.chatController.isThinking,
                          isCancelling: widget.chatController.isCancelling,
                          onSend: _send,
                          onCancel: widget.chatController.cancelActiveTurn,
                          onClear: _confirmClearHistory,
                          onCompress: _sendCompact,
                          onExportMarkdown: _exportMarkdown,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopChatHeader extends StatelessWidget {
  const _DesktopChatHeader({
    required this.agentsController,
    required this.chatController,
    required this.onSearch,
    this.acrylic = false,
  });

  final CliAgentsController agentsController;
  final BotChatController chatController;
  final VoidCallback onSearch;
  final bool acrylic;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ChatChromeSurface(
      acrylic: acrylic,
      color: colors.surface,
      border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      child: SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 10, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: _ChatTitle(
                  agentsController: agentsController,
                  chatController: chatController,
                ),
              ),
              _SearchButton(
                chatController: chatController,
                onPressed: onSearch,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatTitle extends StatelessWidget {
  const _ChatTitle({
    required this.agentsController,
    required this.chatController,
  });

  final CliAgentsController agentsController;
  final BotChatController chatController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        agentsController,
        chatController,
      ]),
      builder: (BuildContext context, Widget? _) {
        // In a conversation the title names the workspace and the subtitle the
        // agent and session, e.g. "Relay" over "Claude Code - Main".
        final bool hasChatTarget = chatController.machine != null;
        final String agentLabel = agentsController.activeAgent.label;
        final String? workdir = chatController.activeWorkdir;
        final AgentSession? session = chatController.activeSession;
        final String subtitle = hasChatTarget
            ? <String>[agentLabel, if (session != null) session.name]
                .join(' - ')
            : '';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              !hasChatTarget
                  ? context.l10n.home
                  : workdir == null
                      ? agentLabel
                      : workdirName(workdir),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                  fontSize: 12,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _SearchButton extends StatelessWidget {
  const _SearchButton({required this.chatController, required this.onPressed});

  final BotChatController chatController;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: chatController,
      builder: (BuildContext context, Widget? _) {
        if (chatController.machine == null) {
          return const SizedBox.shrink();
        }
        return IconButton(
          icon: const Icon(Icons.search_rounded),
          tooltip: context.l10n.searchChats,
          onPressed: chatController.isThinking ? null : onPressed,
        );
      },
    );
  }
}

class _NotLoggedInBanner extends StatelessWidget {
  const _NotLoggedInBanner({required this.agentLabel, required this.onRecheck});

  final String agentLabel;
  final Future<void> Function() onRecheck;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ChatChromeSurface(
      acrylic: WallpaperScope.enabledOf(context),
      color: colors.errorContainer,
      border: const Border(),
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
                style: TextStyle(color: colors.onErrorContainer, fontSize: 13),
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
  const _EmptyChatPlaceholder({
    required this.agentKey,
    required this.agentName,
  });

  final String agentKey;
  final String agentName;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AgentIcon(agentKey: agentKey, size: 40),
          const SizedBox(height: 14),
          Text(
            context.l10n.startChat(agentName),
            style: TextStyle(
              color: Theme.of(context).colorScheme.outline,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
