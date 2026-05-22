// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

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

  @override
  void initState() {
    super.initState();
    widget.chatController.addListener(_scrollToBottomSoon);
    widget.agentsController.addListener(_onContextChanged);
    widget.machinesController.addListener(_onContextChanged);
    widget.settingsController.addListener(_onSettingsChanged);
    _syncContext();
  }

  @override
  void dispose() {
    widget.chatController.removeListener(_scrollToBottomSoon);
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
    await widget.chatController.sendUserText('/compact');
  }

  Future<String> _transcribeRecording(String path) {
    return widget.chatController.transcribeAudioFile(
      path: path,
      language: widget.settingsController.sttLanguage.apiValue,
    );
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
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
    return Scaffold(
      drawerScrimColor: Colors.black54,
      drawer: Drawer(
        child: SafeArea(
          child: CliAgentsDrawer(
            agentsController: widget.agentsController,
            chatController: widget.chatController,
            machinesController: widget.machinesController,
            settingsController: widget.settingsController,
          ),
        ),
      ),
      appBar: AppBar(
        leading: Builder(
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
                Expanded(
                  child: widget.chatController.messages.isEmpty
                      ? _EmptyChatPlaceholder(agentName: agent.label)
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                          itemCount: widget.chatController.messages.length,
                          itemBuilder: (BuildContext context, int index) {
                            final ChatMessage message =
                                widget.chatController.messages[index];
                            return _MessageBubble(
                              message: message,
                              retryable:
                                  widget.chatController.isRetryable(message),
                              awaitingFirstToken: widget.chatController
                                  .isAwaitingFirstToken(message),
                              errorDetail:
                                  widget.chatController.errorDetailFor(message),
                              system: widget.chatController
                                  .isSystemMessage(message),
                              cancelled:
                                  widget.chatController.isCancelled(message),
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
                  onTranscribeRecording: _transcribeRecording,
                ),
              ],
            );
          },
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
    required this.onTranscribeRecording,
  });

  final TextEditingController controller;
  final bool isThinking;
  final bool isCancelling;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final Future<String> Function(String path) onTranscribeRecording;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _isTranscribing = false;
  Timer? _recordingTimer;
  String? _recordingPath;

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopAndTranscribe();
      return;
    }
    if (_isTranscribing || widget.isThinking) return;

    final bool allowed = await _recorder.hasPermission();
    if (!allowed) {
      _showError(context.l10n.microphonePermissionDenied);
      return;
    }

    final Directory tempDir = await getTemporaryDirectory();
    final String path =
        '${tempDir.path}/agentdeck-voice-${DateTime.now().microsecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 16000,
      ),
      path: path,
    );
    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _recordingPath = path;
    });
    _recordingTimer?.cancel();
    _recordingTimer = Timer(const Duration(seconds: 60), () {
      if (mounted && _isRecording) unawaited(_stopAndTranscribe());
    });
  }

  Future<void> _stopAndTranscribe() async {
    _recordingTimer?.cancel();
    final String? path = await _recorder.stop() ?? _recordingPath;
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isTranscribing = true;
      _recordingPath = null;
    });

    try {
      if (path == null || path.isEmpty) return;
      final String text = await widget.onTranscribeRecording(path);
      if (!mounted || text.trim().isEmpty) return;
      _appendInput(text.trim());
    } catch (err) {
      if (mounted) _showError(context.l10n.transcriptionFailed(err));
    } finally {
      if (path != null && path.isNotEmpty) {
        unawaited(_deleteRecording(path));
      }
      if (mounted) setState(() => _isTranscribing = false);
    }
  }

  Future<void> _deleteRecording(String path) async {
    try {
      await File(path).delete();
    } catch (_) {
      // Best effort cleanup.
    }
  }

  void _appendInput(String text) {
    final String current = widget.controller.text.trim();
    final String next = current.isEmpty ? text : '$current\n$text';
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool canSend = !widget.isThinking && !_isTranscribing;
    final bool canCancel = widget.isThinking && !widget.isCancelling;
    final bool canRecord = !widget.isThinking && !_isTranscribing;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: widget.controller,
                enabled: canSend,
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
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: canRecord || _isRecording ? _toggleRecording : null,
              icon: _isTranscribing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _isRecording
                          ? Icons.stop_circle_outlined
                          : Icons.mic_none_rounded,
                    ),
              tooltip: _isTranscribing
                  ? context.l10n.transcribing
                  : _isRecording
                      ? context.l10n.stopRecording
                      : context.l10n.startRecording,
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
                  SelectableText(
                    message.content,
                    style: TextStyle(
                      color: textColor,
                      height: 1.45,
                      fontSize: 15,
                    ),
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
