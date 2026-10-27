// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/backend/backend_client.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/util/error_text.dart';
import '../../core/widgets/chat_wallpaper.dart';
import 'agent_controls.dart';

class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.backend,
    required this.agentKey,
    required this.sessionId,
    required this.isThinking,
    required this.isCancelling,
    required this.onSend,
    required this.onCancel,
    required this.onClear,
    required this.onCompress,
    required this.onExportMarkdown,
    this.header,
    this.acrylic = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// Pinned above the field: the active agent's quota.
  final Widget? header;
  final bool acrylic;
  final BackendClient backend;
  final String agentKey;
  final String? sessionId;
  final bool isThinking;
  final bool isCancelling;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final VoidCallback onClear;
  final VoidCallback onCompress;
  final VoidCallback onExportMarkdown;

  @override
  State<ChatInputBar> createState() => _InputBarState();
}

class _InputBarState extends State<ChatInputBar> {
  static const int _maxUploadBytes = 100 * 1024 * 1024;

  bool _actionsOpen = false;
  bool _hasText = false;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.trim().isNotEmpty;
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      _hasText = widget.controller.text.trim().isNotEmpty;
      widget.controller.addListener(_onTextChanged);
    }
    // Hardware-keyboard targets should stay ready for the next prompt after a
    // turn finishes. On mobile we leave focus alone so the soft keyboard does
    // not reopen after every reply.
    if (usesHardwareKeyboard && oldWidget.isThinking && !widget.isThinking) {
      widget.focusNode.requestFocus();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    widget.focusNode.removeListener(_onFocusChanged);
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
    if (!widget.focusNode.hasFocus || !_actionsOpen) return;
    setState(() => _actionsOpen = false);
  }

  void _toggleActions() {
    widget.focusNode.unfocus();
    setState(() => _actionsOpen = !_actionsOpen);
  }

  void _closeActions() {
    if (!_actionsOpen) return;
    setState(() => _actionsOpen = false);
  }

  void _sendText() {
    // Sending is allowed even while a turn runs: the controller queues the text
    // as a follow-up and auto-sends it when the conversation frees up.
    if (!_hasText) return;
    _closeActions();
    widget.onSend();
  }

  void _runAction(VoidCallback action) {
    _closeActions();
    action();
  }

  Future<void> _attachFiles() async {
    if (_isUploading) return;
    _closeActions();
    setState(() => _isUploading = true);
    try {
      final FilePickerResult? result = await FilePicker.pickFiles(
        allowMultiple: true,
        withData: kIsWeb,
        withReadStream: !kIsWeb,
      );
      if (result == null || !mounted) return;
      for (final PlatformFile file in result.files) {
        if (!mounted) return;
        if (kIsWeb ? file.bytes == null : file.readStream == null) continue;
        final int length = kIsWeb ? file.bytes!.length : file.size;
        if (length > _maxUploadBytes) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.l10n.uploadTooLarge(file.name, '100 MB')),
            ),
          );
          continue;
        }
        final String timestamp = DateTime.now()
            .toIso8601String()
            .split('.')
            .first
            .replaceAll(RegExp('[-:]'), '')
            .replaceFirst('T', '-');
        final String name = '$timestamp-${file.name}';
        final FsEntry entry = kIsWeb
            ? await widget.backend.uploadFile(
                path: '.relay/uploads',
                name: name,
                bytes: file.bytes!,
                createDirectory: true,
              )
            : await widget.backend.uploadFileStream(
                path: '.relay/uploads',
                name: name,
                bytes: file.readStream!,
                length: length,
                createDirectory: true,
              );
        if (!mounted) return;
        final String draft = widget.controller.text;
        final String separator =
            draft.isEmpty || draft.endsWith('\n') ? '' : '\n';
        final String text = '$draft$separator${entry.path}';
        widget.controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.uploadFailed(friendlyErrorText(context.l10n, err)),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _submitFromKeyboard() {
    if (!usesHardwareKeyboard) return;
    _sendText();
  }

  @override
  Widget build(BuildContext context) {
    final bool canCancel = widget.isThinking && !widget.isCancelling;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget input = _MessageTextField(
      acrylic: widget.acrylic,
      focusNode: widget.focusNode,
      controller: widget.controller,
      enabled: true,
      hintText: widget.isThinking
          ? context.l10n.inputHintFollowUp
          : context.l10n.inputHint,
      onTap: _closeActions,
    );
    return ChatChromeSurface(
      acrylic: widget.acrylic,
      color: colors.surfaceContainer,
      border: Border(top: BorderSide(color: colors.outlineVariant)),
      // The gesture bar's own inset is the bottom gap; 12 only where it has none.
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.header != null) widget.header!,
              if (_isUploading) const LinearProgressIndicator(minHeight: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: usesHardwareKeyboard
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
                  // Always available, even mid-turn: model and other controls
                  // apply from the next turn.
                  SizedBox.square(
                    dimension: 44,
                    child: IconButton.filledTonal(
                      isSelected: _actionsOpen,
                      onPressed: _toggleActions,
                      icon: const Icon(Icons.add_rounded),
                      selectedIcon: const Icon(Icons.close_rounded),
                      tooltip: context.l10n.moreChatActions,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // With text it sends (queuing a follow-up while a turn runs);
                  // with no text mid-turn it stops the turn.
                  SizedBox.square(
                    dimension: 44,
                    child: IconButton.filled(
                      onPressed: _hasText
                          ? _sendText
                          : canCancel
                              ? widget.onCancel
                              : null,
                      icon: Icon(
                        !_hasText && widget.isThinking
                            ? Icons.stop_rounded
                            : Icons.arrow_upward_rounded,
                      ),
                      tooltip: !_hasText && widget.isThinking
                          ? context.l10n.stop
                          : context.l10n.send,
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
                        sessionId: widget.sessionId,
                        busy: widget.isThinking,
                        onAttachFile: _isUploading ? null : _attachFiles,
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
      ),
    );
  }
}

class _MessageTextField extends StatelessWidget {
  const _MessageTextField({
    required this.focusNode,
    required this.controller,
    required this.enabled,
    required this.hintText,
    required this.onTap,
    this.acrylic = false,
  });

  final FocusNode focusNode;
  final TextEditingController controller;
  final bool enabled;
  final String hintText;
  final VoidCallback onTap;
  final bool acrylic;

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
        hintText: hintText,
        filled: true,
        fillColor:
            acrylic ? colors.surface.withValues(alpha: 0.18) : colors.surface,
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
    required this.sessionId,
    required this.busy,
    required this.onAttachFile,
    required this.onOpenSettingsPage,
    required this.onClear,
    required this.onCompress,
    required this.onExportMarkdown,
  });

  final BackendClient backend;
  final String agentKey;
  final String? sessionId;

  /// A turn is running: clearing and compacting need an idle session.
  final bool busy;
  final VoidCallback? onAttachFile;
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
            sessionId: sessionId,
            onOpenPage: onOpenSettingsPage,
          ),
          const SizedBox(height: 14),
          ComposerActionRow(
            children: <Widget>[
              ComposerActionButton(
                icon: Icons.attach_file,
                label: context.l10n.attachFile,
                onPressed: onAttachFile,
              ),
              ComposerActionButton(
                icon: Icons.refresh_rounded,
                label: context.l10n.clearChat,
                onPressed: busy ? null : onClear,
              ),
              ComposerActionButton(
                icon: Icons.compress,
                label: context.l10n.compress,
                onPressed: busy ? null : onCompress,
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
