import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/backend/backend_client.dart';

enum BrowserStatus {
  connecting,
  connected,
  disconnected,
  replaced,
  exited,
  failed
}

/// What the backend tells the page beyond frames: a JavaScript dialog it
/// accepted, an address it refused, or a new tab's address to open on the
/// device.
typedef BrowserNotice = ({String kind, String message});

/// One headless browser on the backend machine, shown as a stream of JPEG
/// frames, with pointer and keyboard input sent back as JSON.
class BrowserController extends ChangeNotifier {
  BrowserController({required BackendClient backend}) : _backend = backend;

  final BackendClient _backend;

  /// The latest frame. Kept apart from [notifyListeners] so a new frame
  /// repaints only the picture, not the address bar.
  final ValueNotifier<Uint8List?> frame = ValueNotifier<Uint8List?>(null);
  void Function(BrowserNotice notice)? onNotice;

  BrowserStatus _status = BrowserStatus.disconnected;
  String _url = '';
  Object? _error;
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  Map<String, Object?>? _viewport;
  bool _hasConnected = false;
  bool _disposed = false;
  int _generation = 0;

  BrowserStatus get status => _status;
  bool get connected => status == BrowserStatus.connected;

  /// The page address, empty while nothing has been opened.
  String get url => _url;

  /// Why the browser is [BrowserStatus.failed] or disconnected: an exception
  /// or the backend's message.
  Object? get error => _error;

  Future<void> connect() async {
    if (_disposed) return;
    final int generation = ++_generation;
    _reconnectTimer?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _error = null;
    _setStatus(BrowserStatus.connecting);
    WebSocketChannel? channel;
    try {
      final Uri uri = await _backend.browserWebSocketUri();
      if (_disposed || generation != _generation) return;
      channel = WebSocketChannel.connect(uri);
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 15));
      if (_disposed || generation != _generation) {
        await channel.sink.close();
        return;
      }
      channel.stream.listen(
        (Object? raw) => _handleMessage(raw, generation),
        onError: (Object err) => _handleClose(generation, err),
        onDone: () => _handleClose(generation, null),
        cancelOnError: true,
      );
    } catch (err) {
      if (_disposed || generation != _generation) return;
      await channel?.sink.close();
      _channel = null;
      _error = err;
      _setStatus(BrowserStatus.failed);
    }
  }

  void navigate(String address) {
    final String text = address.trim();
    if (text.isNotEmpty) {
      _send(<String, Object?>{'type': 'navigate', 'url': text});
    }
  }

  void back() => _send(<String, Object?>{'type': 'back'});
  void reload() => _send(<String, Object?>{'type': 'reload'});
  void sendText(String text) {
    if (text.isNotEmpty) _send(<String, Object?>{'type': 'text', 'text': text});
  }

  void sendKey(String key) =>
      _send(<String, Object?>{'type': 'key', 'key': key});

  /// The viewport is the picture's own size in logical pixels, so pointer
  /// positions need no scaling. [mobile] turns on Chrome's touch and
  /// mobile-layout emulation.
  void resize({
    required double width,
    required double height,
    required double scale,
    required bool mobile,
  }) {
    final Map<String, Object?> viewport = <String, Object?>{
      'type': 'resize',
      'width': width.round(),
      'height': height.round(),
      'scale': scale,
      'mobile': mobile,
    };
    if (mapEquals(viewport, _viewport)) return;
    _viewport = viewport;
    _send(viewport);
  }

  void sendMouse(
    String event,
    Offset position, {
    String button = 'none',
    int buttons = 0,
    int clickCount = 0,
    Offset delta = Offset.zero,
  }) {
    _send(<String, Object?>{
      'type': 'mouse',
      'event': event,
      'x': position.dx,
      'y': position.dy,
      'button': button,
      'buttons': buttons,
      'clickCount': clickCount,
      'deltaX': delta.dx,
      'deltaY': delta.dy,
    });
  }

  /// [points] are every finger still down, as the touch protocol expects.
  void sendTouch(String event, Map<int, Offset> points) {
    _send(<String, Object?>{
      'type': 'touch',
      'event': event,
      'points': <Map<String, Object?>>[
        for (final MapEntry<int, Offset> point in points.entries)
          <String, Object?>{
            'id': point.key,
            'x': point.value.dx,
            'y': point.value.dy,
          },
      ],
    });
  }

  void _handleMessage(Object? raw, int generation) {
    if (_disposed || generation != _generation) return;
    if (raw is List<int>) {
      frame.value = raw is Uint8List ? raw : Uint8List.fromList(raw);
      return;
    }
    if (raw is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    switch (decoded['type']) {
      case 'ready':
        _hasConnected = true;
        _setUrl(decoded['url']);
        _setStatus(BrowserStatus.connected);
        final Map<String, Object?>? viewport = _viewport;
        if (viewport != null) _send(viewport);
      case 'url':
        _setUrl(decoded['url']);
      case 'dialog':
        onNotice
            ?.call((kind: 'dialog', message: '${decoded['message'] ?? ''}'));
      case 'rejected':
        onNotice
            ?.call((kind: 'rejected', message: '${decoded['message'] ?? ''}'));
      case 'open':
        onNotice?.call((kind: 'open', message: '${decoded['url'] ?? ''}'));
      case 'replaced':
        _setStatus(BrowserStatus.replaced);
      case 'exit':
        _setStatus(BrowserStatus.exited);
      case 'error':
        _error = '${decoded['message'] ?? 'Browser failed.'}';
        _setStatus(BrowserStatus.failed);
    }
  }

  void _setUrl(Object? value) {
    final String next = value is String && value != 'about:blank' ? value : '';
    if (next == _url) return;
    _url = next;
    notifyListeners();
  }

  void _handleClose(int generation, Object? err) {
    if (_disposed || generation != _generation) return;
    _channel = null;
    if (_status != BrowserStatus.connected &&
        _status != BrowserStatus.connecting) {
      return;
    }
    if (err != null) _error = err;
    _setStatus(BrowserStatus.disconnected);
    // A phone drops the socket in the background; the backend keeps the page.
    if (!_hasConnected) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 1), () {
      if (!_disposed && generation == _generation) unawaited(connect());
    });
  }

  void _send(Map<String, Object?> message) {
    if (!connected) return;
    try {
      _channel?.sink.add(jsonEncode(message));
    } catch (_) {
      // The stream listener handles the close.
    }
  }

  void _setStatus(BrowserStatus value) {
    if (_status == value || _disposed) return;
    _status = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    unawaited(_channel?.sink.close());
    frame.dispose();
    super.dispose();
  }
}
