import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../core/i18n/app_strings.dart';
import 'ssh_terminal_controller.dart';

class SshTerminalScreen extends StatefulWidget {
  const SshTerminalScreen({
    required this.controller,
    required this.machineId,
    super.key,
  });

  final SshTerminalController controller;
  final String machineId;

  @override
  State<SshTerminalScreen> createState() => _SshTerminalScreenState();
}

class _SshTerminalScreenState extends State<SshTerminalScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.connect(widget.machineId);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, Widget? _) {
        final ThemeData theme = Theme.of(context);
        final TerminalTheme terminalTheme = _terminalTheme(theme);
        return Scaffold(
          backgroundColor: terminalTheme.background,
          appBar: AppBar(
            leading: IconButton(
              tooltip: context.l10n.backToCredentials,
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            title: Text(context.l10n.sshTerminal),
            actions: <Widget>[
              if (widget.controller.status == SshTerminalStatus.connecting ||
                  widget.controller.status == SshTerminalStatus.disconnected)
                const Padding(
                  padding: EdgeInsets.only(right: 18),
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
            ],
          ),
          body: SafeArea(
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: KeyedSubtree(
                    key: ObjectKey(widget.controller.terminal),
                    child: TerminalView(
                      widget.controller.terminal,
                      controller: widget.controller.terminalController,
                      theme: terminalTheme,
                      textStyle: const TerminalStyle(
                        fontSize: 14,
                        fontFamily: 'RelayTerminalMono',
                        fontFamilyFallback: <String>[
                          'Cascadia Mono',
                          'Consolas',
                          'Menlo',
                          'Monaco',
                          'Liberation Mono',
                          'DejaVu Sans Mono',
                          'Noto Sans Mono',
                          'Noto Sans Mono CJK SC',
                          'Noto Sans Mono CJK TC',
                          'Noto Sans Mono CJK KR',
                          'Noto Sans Mono CJK JP',
                          'Noto Color Emoji',
                          'Noto Sans Symbols',
                          'monospace',
                        ],
                      ),
                      padding: const EdgeInsets.all(8),
                      autofocus: true,
                      deleteDetection: true,
                      keyboardAppearance: theme.brightness,
                      onSecondaryTapDown: (TapDownDetails details, _) async {
                        final TerminalController controller =
                            widget.controller.terminalController;
                        final selection = controller.selection;
                        if (selection != null) {
                          final String text = widget.controller.terminal.buffer
                              .getText(selection);
                          controller.clearSelection();
                          await Clipboard.setData(ClipboardData(text: text));
                          return;
                        }
                        final ClipboardData? data =
                            await Clipboard.getData('text/plain');
                        if (data?.text != null) {
                          widget.controller.terminal.paste(data!.text!);
                        }
                      },
                    ),
                  ),
                ),
                if (_showBlockingState(widget.controller.status))
                  Positioned.fill(
                    child: ColoredBox(
                      color: terminalTheme.background.withValues(alpha: 0.94),
                      child: _TerminalStateMessage(
                        controller: widget.controller,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _showBlockingState(SshTerminalStatus status) {
    return status == SshTerminalStatus.failed ||
        status == SshTerminalStatus.exited ||
        status == SshTerminalStatus.replaced;
  }
}

class _TerminalStateMessage extends StatelessWidget {
  const _TerminalStateMessage({required this.controller});

  final SshTerminalController controller;

  @override
  Widget build(BuildContext context) {
    final String message = switch (controller.status) {
      SshTerminalStatus.exited => context.l10n.sshTerminalExited,
      SshTerminalStatus.replaced => context.l10n.sshTerminalReplaced,
      _ => controller.error ?? context.l10n.sshTerminalConnectionFailed,
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: controller.retry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

TerminalTheme _terminalTheme(ThemeData theme) {
  final bool dark = theme.brightness == Brightness.dark;
  final Color background = theme.scaffoldBackgroundColor;
  final Color foreground =
      dark ? const Color(0xFFEAF6FF) : const Color(0xFF101923);
  return TerminalTheme(
    cursor: foreground,
    selection: theme.colorScheme.primary.withValues(alpha: 0.35),
    foreground: foreground,
    background: background,
    black: dark ? const Color(0xFF071019) : const Color(0xFF101923),
    red: dark ? const Color(0xFFF14C4C) : const Color(0xFFB42318),
    green: dark ? const Color(0xFF23D18B) : const Color(0xFF067647),
    yellow: dark ? const Color(0xFFF5F543) : const Color(0xFFB54708),
    blue: dark ? const Color(0xFF3B8EEA) : const Color(0xFF175CD3),
    magenta: dark ? const Color(0xFFD670D6) : const Color(0xFF9E3F95),
    cyan: dark ? const Color(0xFF29B8DB) : const Color(0xFF087E8B),
    white: dark ? const Color(0xFFE5E5E5) : const Color(0xFFEAF0F6),
    brightBlack: const Color(0xFF667085),
    brightRed: const Color(0xFFF97066),
    brightGreen: const Color(0xFF12B76A),
    brightYellow: const Color(0xFFF79009),
    brightBlue: const Color(0xFF53B1FD),
    brightMagenta: const Color(0xFFEE46BC),
    brightCyan: const Color(0xFF06AED4),
    brightWhite: dark ? const Color(0xFFFFFFFF) : const Color(0xFFF9FAFB),
    searchHitBackground: const Color(0xFFFDB022),
    searchHitBackgroundCurrent: const Color(0xFF12B76A),
    searchHitForeground: const Color(0xFF101923),
  );
}
