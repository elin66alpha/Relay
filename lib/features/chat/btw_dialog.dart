import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/chat_message.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/util/time_format.dart';
import 'btw_controller.dart';

/// The /btw sidekick popup. Opened from the chat header; it forks the current
/// conversation on the backend so the side chat shares its memory but never
/// touches the main task.
class BtwDialog extends StatefulWidget {
  const BtwDialog({
    required this.backend,
    required this.agentKey,
    required this.sessionId,
    required this.language,
    super.key,
  });

  final BackendClient backend;
  final String agentKey;
  final String sessionId;
  final AppLanguage language;

  static Future<void> show(
    BuildContext context, {
    required BackendClient backend,
    required String agentKey,
    required String sessionId,
    required AppLanguage language,
  }) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext _) => BtwDialog(
        backend: backend,
        agentKey: agentKey,
        sessionId: sessionId,
        language: language,
      ),
    );
  }

  @override
  State<BtwDialog> createState() => _BtwDialogState();
}

class _BtwDialogState extends State<BtwDialog> {
  late final BtwController _controller;
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller = BtwController(
      backendClient: widget.backend,
      agentKey: widget.agentKey,
      sessionId: widget.sessionId,
      language: widget.language,
    );
    _controller.addListener(_onChanged);
    _controller.load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.minScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final String text = _input.text;
    if (text.trim().isEmpty || _controller.isThinking) return;
    _input.clear();
    await _controller.send(text);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<ChatMessage> messages = _controller.messages;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _header(context, colors),
            const Divider(height: 1),
            Expanded(
              child: _controller.isLoading && messages.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : messages.isEmpty
                      ? _empty(context, colors)
                      // SelectionArea keeps bubble text selectable without
                      // per-bubble overlay-based SelectableText, which crashed
                      // on teardown (InheritedElement '_dependents.isEmpty').
                      : SelectionArea(
                          child: ListView.builder(
                          controller: _scroll,
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                          itemCount: messages.length,
                          itemBuilder: (BuildContext context, int index) {
                            final ChatMessage message =
                                messages[messages.length - 1 - index];
                            return _BtwBubble(
                              message: message,
                              awaiting: _controller.isAwaiting(message),
                              errorDetail: _controller.errorDetailFor(message),
                            );
                          },
                        ),
                        ),
            ),
            const Divider(height: 1),
            _inputBar(context, colors),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: <Widget>[
          Text(
            'BTW',
            style: TextStyle(
              color: colors.primary,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  context.l10n.btwTitle,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  context.l10n.btwSubtitle,
                  style: TextStyle(fontSize: 11, color: colors.outline),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: context.l10n.btwClearTitle,
            onPressed: _controller.isThinking ? null : _controller.clear,
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: context.l10n.close,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, ColorScheme colors) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          context.l10n.btwEmpty,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.outline),
        ),
      ),
    );
  }

  Widget _inputBar(BuildContext context, ColorScheme colors) {
    final bool thinking = _controller.isThinking;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: context.l10n.btwHint,
                filled: true,
                fillColor: colors.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox.square(
            dimension: 44,
            child: IconButton.filledTonal(
              onPressed: thinking
                  ? _controller.cancel
                  : _input.text.trim().isEmpty
                      ? null
                      : _send,
              icon: Icon(
                thinking ? Icons.stop_rounded : Icons.arrow_upward_rounded,
              ),
              tooltip: thinking ? context.l10n.stop : context.l10n.send,
            ),
          ),
        ],
      ),
    );
  }
}

class _BtwBubble extends StatelessWidget {
  const _BtwBubble({
    required this.message,
    required this.awaiting,
    required this.errorDetail,
  });

  final ChatMessage message;
  final bool awaiting;
  final String? errorDetail;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool isUser = message.isUser;
    final Color bubbleColor =
        isUser ? colors.primary : colors.surfaceContainerHighest;
    final Color textColor = isUser ? colors.onPrimary : colors.onSurface;
    final TextStyle textStyle =
        TextStyle(color: textColor, height: 1.4, fontSize: 14);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            ),
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(12),
              border: isUser ? null : Border.all(color: colors.outlineVariant),
            ),
            child: awaiting && message.content.isEmpty
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: textColor,
                    ),
                  )
                : isUser
                    ? Text(message.content, style: textStyle)
                    : MarkdownBody(
                        data: message.content,
                        selectable: false,
                        styleSheet: MarkdownStyleSheet(p: textStyle),
                      ),
          ),
          if (errorDetail != null && errorDetail!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              child: Text(
                errorDetail!,
                style: TextStyle(fontSize: 11, color: colors.error),
              ),
            )
          else if (!(awaiting && message.content.isEmpty))
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
              child: Text(
                formatShortTime(context, message.createdAt.toIso8601String()),
                style: TextStyle(fontSize: 10, color: colors.outline),
              ),
            ),
        ],
      ),
    );
  }
}
