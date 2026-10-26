// ignore_for_file: use_build_context_synchronously

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/chat_message.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/util/time_format.dart';
import '../../core/widgets/chat_wallpaper.dart';
import 'chat_content.dart';

// A centered, muted one-line status note (e.g. "Conversation compacted")
// rendered inline in the message list instead of as a chat bubble.
class ChatNotice extends StatelessWidget {
  const ChatNotice({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
      ),
    );
  }
}

// The turn's persisted execution steps.
List<String> _persistedSteps(ChatMessage message) {
  final Object? raw = message.metadata['progressLines'];
  if (raw is! List) return const <String>[];
  return raw
      .whereType<String>()
      .where((String line) => line.trim().isNotEmpty)
      .toList(growable: false);
}

/// Pulses a tint behind the message a "search chats" jump landed on, so the eye
/// finds the row once the list stops scrolling. Only ever wraps that one row:
/// the fade runs on mount and the wrapper is dropped when the highlight clears.
class SearchMatchFlash extends StatefulWidget {
  const SearchMatchFlash({required this.child, super.key});

  final Widget child;

  @override
  State<SearchMatchFlash> createState() => _SearchMatchFlashState();
}

class _SearchMatchFlashState extends State<SearchMatchFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 520),
  );
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _fade.forward();
    _hold = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) _fade.reverse();
    });
  }

  @override
  void dispose() {
    _hold?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color tint = Theme.of(context).colorScheme.tertiary;
    return AnimatedBuilder(
      animation: _fade,
      builder: (BuildContext context, Widget? child) => DecoratedBox(
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.18 * _fade.value),
          borderRadius: BorderRadius.circular(14),
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

class BotMessageBubble extends StatelessWidget {
  const BotMessageBubble({
    super.key,
    required this.message,
    required this.retryable,
    required this.streaming,
    required this.awaitingFirstToken,
    required this.errorDetail,
    required this.system,
    required this.cancelled,
    required this.queued,
    required this.progressLines,
    required this.onRetry,
    required this.onEdit,
    required this.onCancelQueued,
    required this.onOptionSelected,
    required this.agentKey,
    required this.agentLabel,
    this.highlightQuery,
  });

  final ChatMessage message;

  /// The conversation's agent, named in each reply's header.
  final String agentKey;
  final String agentLabel;

  /// Set only while this bubble is the revealed "search chats" hit; marks the
  /// term inside the rendered text.
  final String? highlightQuery;

  final bool retryable;
  final bool streaming;
  final bool awaitingFirstToken;
  final String? errorDetail;
  final bool system;
  final bool cancelled;
  final bool queued;
  final List<String> progressLines;
  final VoidCallback onRetry;
  final VoidCallback onEdit;
  final VoidCallback onCancelQueued;
  final void Function(String option) onOptionSelected;

  @override
  Widget build(BuildContext context) {
    final bool isUser = message.isUser;
    final bool acrylic = WallpaperScope.enabledOf(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double maxBubbleWidth =
        isDesktopTarget ? 760 : MediaQuery.sizeOf(context).width * 0.80;
    final Color textColor = isUser && !system
        ? (acrylic ? colors.onPrimaryContainer : colors.onPrimary)
        : colors.onSurface;

    // A turn can leave several assistant messages (mid-task follow-ups + a final
    // answer); render them as separate, individually timestamped blocks. A single
    // message keeps the simpler one-block layout with a single timestamp below.
    final List<MessageSegment> segments = message.segments;
    final bool segmented = !isUser && !system && segments.length > 1;
    // Claude sometimes ends a finished answer with a "pick one" question + list;
    // surface those choices as buttons that send the pick back as a new message.
    final List<String>? optionPrompt = (!isUser && !system && !streaming)
        ? parseOptionPrompt(
            segments.isNotEmpty ? segments.last.text : message.content,
          )
        : null;
    // Claude and Codex often open with an "I will …" plan; fold it away on the
    // finished bubble.
    final ({String plan, String body})? planSplit = (!isUser &&
            !system &&
            !streaming &&
            !segmented &&
            message.content.isNotEmpty)
        ? splitLeadingPlan(message.content)
        : null;
    // Execution steps captured during the turn, surfaced collapsed once it ends
    // (live progress still streams via `progressLines` below while running).
    final List<String> finishedSteps = (!isUser && !system && !streaming)
        ? _persistedSteps(message)
        : const <String>[];
    final DateTime stampTime =
        (!isUser && segments.isNotEmpty && segments.first.createdAt != null)
            ? segments.first.createdAt!
            : message.createdAt;
    final bool showStamp =
        !segmented && !(awaitingFirstToken && message.content.isEmpty);
    // An agent reply names its agent and time in a header line; the user's
    // bubble and a system reply keep the time underneath.
    final bool hasHeader = !isUser && !system;
    final Widget? actions =
        !streaming && !awaitingFirstToken && !queued && !system
            ? _MessageActions(
                text: isUser
                    ? message.content
                    : segmented
                        // The same segment SegmentedContent shows last.
                        ? segments
                            .lastWhere(
                              (MessageSegment s) => s.text.trim().isNotEmpty,
                              orElse: () => segments.last,
                            )
                            .text
                        : planSplit?.body ?? message.content,
                onEdit: isUser ? onEdit : null,
              )
            : null;

    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (awaitingFirstToken && message.content.isEmpty)
          TypingDots(color: textColor)
        else if (segmented)
          SegmentedContent(
            segments: segments,
            color: textColor,
            formatInlineEmphasis: !streaming,
            highlightQuery: highlightQuery,
            trailing: actions,
          )
        else if (message.content.isNotEmpty)
          if (planSplit != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                CollapsibleNote(
                  title: context.l10n.agentThinking,
                  color: textColor,
                  child: MessageText(
                    text: planSplit.plan,
                    color: textColor,
                    formatInlineEmphasis: true,
                    highlightQuery: highlightQuery,
                  ),
                ),
                const SizedBox(height: 8),
                MessageText(
                  text: planSplit.body,
                  color: textColor,
                  formatInlineEmphasis: true,
                  highlightQuery: highlightQuery,
                ),
              ],
            )
          else
            MessageText(
              text: message.content,
              color: textColor,
              formatInlineEmphasis: !isUser && !streaming,
              highlightQuery: highlightQuery,
            ),
        if (optionPrompt != null)
          OptionButtons(
            options: optionPrompt,
            color: textColor,
            onSelected: onOptionSelected,
          ),
        if (progressLines.isNotEmpty) ...<Widget>[
          if (message.content.isNotEmpty) const SizedBox(height: 8),
          ProgressLines(
            lines: progressLines,
            color: textColor,
            active: true,
          ),
        ] else if (finishedSteps.isNotEmpty) ...<Widget>[
          if (message.content.isNotEmpty) const SizedBox(height: 6),
          CollapsibleNote(
            title: context.l10n.agentSteps(finishedSteps.length),
            color: textColor,
            child: ProgressLines(
              lines: finishedSteps,
              color: textColor,
            ),
          ),
        ],
        if (cancelled) ...<Widget>[
          if (message.content.isNotEmpty || progressLines.isNotEmpty)
            const SizedBox(height: 8),
          MessageStatus(
            icon: Icons.stop_circle_outlined,
            text: context.l10n.cancelled,
            color: textColor,
          ),
        ],
      ],
    );

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          if (isUser)
            Container(
              constraints: BoxConstraints(maxWidth: maxBubbleWidth),
              margin: const EdgeInsets.symmetric(vertical: 5),
              child: ChatChromeSurface(
                acrylic: acrylic,
                color: acrylic
                    ? colors.primaryContainer
                    : queued
                        ? colors.primary.withValues(alpha: 0.55)
                        : colors.primary,
                border: acrylic
                    ? Border.all(color: colors.outlineVariant)
                    : const Border(),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                  child: DefaultSelectionStyle.merge(
                    selectionColor: textColor.withValues(alpha: 0.35),
                    child: content,
                  ),
                ),
              ),
            )
          else
            // Replies span the full width: long answers and code read better
            // without a ragged right gutter.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: ReplyPanel(
                color: system ? colors.tertiaryContainer : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (hasHeader)
                      ReplyHeader(
                        agentKey: agentKey,
                        label: agentLabel,
                        time: showStamp
                            ? formatShortTime(
                                context,
                                stampTime.toIso8601String(),
                              )
                            : null,
                        trailing: segmented ? null : actions,
                      ),
                    content,
                  ],
                ),
              ),
            ),
          // A pending follow-up shows a "queued" affordance instead of a time:
          // it has not been sent yet and can still be cancelled.
          if (queued)
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.schedule_rounded, size: 13, color: colors.outline),
                  const SizedBox(width: 4),
                  Text(
                    context.l10n.queuedFollowUp,
                    style: TextStyle(fontSize: 11, color: colors.outline),
                  ),
                  const SizedBox(width: 10),
                  InkWell(
                    onTap: onCancelQueued,
                    child: Text(
                      context.l10n.cancel,
                      style: TextStyle(fontSize: 11, color: colors.primary),
                    ),
                  ),
                ],
              ),
            )
          // Every message shows when it was sent/received. Segmented bubbles also
          // carry an inline time per follow-up, so the trailing stamp is hidden
          // for them to avoid duplicating the last segment's time.
          else if (showStamp && !hasHeader)
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    formatShortTime(context, stampTime.toIso8601String()),
                    style: TextStyle(fontSize: 11, color: colors.outline),
                  ),
                  if (actions != null) actions,
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

class _MessageActions extends StatelessWidget {
  const _MessageActions({required this.text, this.onEdit});

  final String text;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.outline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.copied)),
            );
          },
          tooltip: context.l10n.copy,
          icon: const Icon(Icons.content_copy_rounded),
          iconSize: 14,
          color: color,
          visualDensity: VisualDensity.compact,
        ),
        if (onEdit != null)
          IconButton(
            onPressed: onEdit,
            tooltip: context.l10n.edit,
            icon: const Icon(Icons.edit_outlined),
            iconSize: 14,
            color: color,
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}
