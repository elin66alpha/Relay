import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/util/error_text.dart';
import 'browser_controller.dart';

// Hardware keys the page needs by name; printable characters go as text.
final Map<LogicalKeyboardKey, String> _namedKeys = <LogicalKeyboardKey, String>{
  LogicalKeyboardKey.enter: 'Enter',
  LogicalKeyboardKey.numpadEnter: 'Enter',
  LogicalKeyboardKey.backspace: 'Backspace',
  LogicalKeyboardKey.tab: 'Tab',
  LogicalKeyboardKey.escape: 'Escape',
  LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.home: 'Home',
  LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.pageUp: 'PageUp',
  LogicalKeyboardKey.pageDown: 'PageDown',
  LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
  LogicalKeyboardKey.arrowUp: 'ArrowUp',
  LogicalKeyboardKey.arrowRight: 'ArrowRight',
  LogicalKeyboardKey.arrowDown: 'ArrowDown',
};

/// A page served on the backend machine's localhost, rendered there by a
/// headless browser and operated from here.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({required this.backend, this.controller, super.key});

  final BackendClient backend;

  /// Injected by tests; otherwise the screen owns one.
  final BrowserController? controller;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final BrowserController _controller =
      widget.controller ?? BrowserController(backend: widget.backend);
  final TextEditingController _address = TextEditingController();
  final FocusNode _addressFocus = FocusNode();
  final FocusNode _pageFocus = FocusNode();
  final TextEditingController _typed = TextEditingController();
  final Map<int, Offset> _touches = <int, Offset>{};
  String _pressedButton = 'none';
  bool _keyboardOpen = false;

  // Phones and tablets, natively or in a mobile Web browser, get the page's
  // mobile layout and touch events; desktop and desktop Web get a mouse.
  bool get _mobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncAddress);
    _controller.onNotice = _showNotice;
    _controller.connect();
  }

  @override
  void dispose() {
    _controller.removeListener(_syncAddress);
    _controller.onNotice = null;
    if (widget.controller == null) _controller.dispose();
    _address.dispose();
    _addressFocus.dispose();
    _pageFocus.dispose();
    _typed.dispose();
    super.dispose();
  }

  void _syncAddress() {
    if (!_addressFocus.hasFocus && _address.text != _controller.url) {
      _address.text = _controller.url;
    }
  }

  void _showNotice(BrowserNotice notice) {
    if (!mounted) return;
    final AppStrings strings = context.l10n;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          notice.kind == 'rejected'
              ? strings.browserLocalhostOnly
              : strings.browserDialog(notice.message),
        ),
      ),
    );
  }

  void _go(String text) {
    _controller.navigate(text);
    _pageFocus.requestFocus();
  }

  static String _buttonName(int buttons) {
    if (buttons & kSecondaryMouseButton != 0) return 'right';
    if (buttons & kMiddleMouseButton != 0) return 'middle';
    return 'left';
  }

  bool _isTouch(PointerEvent event) =>
      _mobile &&
      (event.kind == PointerDeviceKind.touch ||
          event.kind == PointerDeviceKind.stylus);

  void _down(PointerDownEvent event) {
    _pageFocus.requestFocus();
    if (_isTouch(event)) {
      _touches[event.pointer] = event.localPosition;
      _controller.sendTouch('touchStart', _touches);
      return;
    }
    _pressedButton = _buttonName(event.buttons);
    _controller.sendMouse(
      'mousePressed',
      event.localPosition,
      button: _pressedButton,
      buttons: event.buttons,
      clickCount: 1,
    );
  }

  void _move(PointerEvent event) {
    if (_isTouch(event)) {
      if (!_touches.containsKey(event.pointer)) return;
      _touches[event.pointer] = event.localPosition;
      _controller.sendTouch('touchMove', _touches);
      return;
    }
    _controller.sendMouse(
      'mouseMoved',
      event.localPosition,
      button: event.buttons == 0 ? 'none' : _pressedButton,
      buttons: event.buttons,
    );
  }

  void _up(PointerEvent event, {bool cancel = false}) {
    if (_isTouch(event)) {
      if (_touches.remove(event.pointer) == null) return;
      _controller.sendTouch(cancel ? 'touchCancel' : 'touchEnd', _touches);
      return;
    }
    _controller.sendMouse(
      'mouseReleased',
      event.localPosition,
      button: _pressedButton,
      clickCount: 1,
    );
    _pressedButton = 'none';
  }

  void _scroll(Offset position, Offset delta) {
    _controller.sendMouse('mouseWheel', position, delta: delta);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final String? named = _namedKeys[event.logicalKey];
    if (named != null) {
      _controller.sendKey(named);
      return KeyEventResult.handled;
    }
    final String? character = event.character;
    final bool shortcut = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (character == null ||
        character.isEmpty ||
        character.codeUnitAt(0) < 0x20 ||
        shortcut) {
      return KeyEventResult.ignored;
    }
    _controller.sendText(character);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? _) {
        final bool connected = _controller.connected;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: TextField(
              controller: _address,
              focusNode: _addressFocus,
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.go,
              decoration: InputDecoration(
                hintText: strings.browserAddressHint,
                border: InputBorder.none,
                isDense: true,
              ),
              onSubmitted: _go,
            ),
            actions: <Widget>[
              IconButton(
                tooltip: strings.browserBack,
                onPressed: connected ? _controller.back : null,
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
              ),
              IconButton(
                tooltip: strings.browserReload,
                onPressed: connected ? _controller.reload : null,
                icon: const Icon(Icons.refresh_rounded),
              ),
              IconButton(
                tooltip: strings.browserKeyboard,
                isSelected: _keyboardOpen,
                onPressed: () => setState(() => _keyboardOpen = !_keyboardOpen),
                icon: const Icon(Icons.keyboard_outlined),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: <Widget>[
                Expanded(child: _page(context)),
                if (_keyboardOpen) _typingBar(strings, connected),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _page(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _controller.resize(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          scale: MediaQuery.devicePixelRatioOf(context),
          mobile: _mobile,
        );
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Focus(
              focusNode: _pageFocus,
              onKeyEvent: _key,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _down,
                onPointerMove: _move,
                onPointerHover: _move,
                onPointerUp: _up,
                onPointerCancel: (PointerCancelEvent event) =>
                    _up(event, cancel: true),
                onPointerSignal: (PointerSignalEvent event) {
                  if (event is PointerScrollEvent) {
                    _scroll(event.localPosition, event.scrollDelta);
                  }
                },
                // Trackpads scroll with pan-zoom events instead of wheel events.
                onPointerPanZoomUpdate: (PointerPanZoomUpdateEvent event) =>
                    _scroll(event.localPosition, -event.panDelta),
                child: ColoredBox(
                  color: Colors.white,
                  child: ValueListenableBuilder<Uint8List?>(
                    valueListenable: _controller.frame,
                    builder: (BuildContext context, Uint8List? bytes, _) =>
                        bytes == null
                            ? const SizedBox.expand()
                            : Image.memory(
                                bytes,
                                gaplessPlayback: true,
                                fit: BoxFit.fill,
                              ),
                  ),
                ),
              ),
            ),
            if (!_controller.connected) _statusOverlay(context),
          ],
        );
      },
    );
  }

  Widget _statusOverlay(BuildContext context) {
    final AppStrings strings = context.l10n;
    final BrowserStatus status = _controller.status;
    final bool busy = status == BrowserStatus.connecting ||
        status == BrowserStatus.disconnected;
    final String message = switch (status) {
      BrowserStatus.replaced => strings.browserReplaced,
      BrowserStatus.exited => strings.browserExited,
      BrowserStatus.failed => _controller.error == null
          ? strings.browserExited
          : friendlyErrorText(strings, _controller.error!),
      _ => strings.browserStarting,
    };
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (busy) const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              if (busy) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  strings.browserLoadingHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                    fontSize: 13,
                  ),
                ),
              ],
              if (!busy) ...<Widget>[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _controller.connect,
                  child: Text(strings.retry),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Soft keyboards cannot type into a picture, so text is composed here
  // (with any IME) and inserted into the focused field on the page.
  Widget _typingBar(AppStrings strings, bool connected) {
    void insert() {
      if (!_controller.connected) return;
      _controller.sendText(_typed.text);
      _typed.clear();
    }

    return Material(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _typed,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: strings.browserTypeHint,
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => insert(),
              ),
            ),
            IconButton(
              tooltip: strings.send,
              onPressed: connected ? insert : null,
              icon: const Icon(Icons.send_rounded),
            ),
            IconButton(
              tooltip: 'Backspace',
              onPressed:
                  connected ? () => _controller.sendKey('Backspace') : null,
              icon: const Icon(Icons.backspace_outlined),
            ),
            IconButton(
              tooltip: 'Enter',
              onPressed: connected ? () => _controller.sendKey('Enter') : null,
              icon: const Icon(Icons.keyboard_return_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
