import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/features/browser/browser_controller.dart';
import 'package:relay_core/features/browser/browser_screen.dart';

void main() {
  test(
      'controller sends the viewport on ready and relays frames, urls and dialogs',
      () async {
    final StreamController<Map<String, Object?>> received =
        StreamController<Map<String, Object?>>();
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.transform(WebSocketTransformer()).listen((WebSocket socket) {
      socket.add(
        jsonEncode(<String, Object?>{'type': 'ready', 'url': 'about:blank'}),
      );
      socket.listen((Object? raw) {
        received.add(jsonDecode(raw! as String) as Map<String, Object?>);
      });
      socket.add(Uint8List.fromList(<int>[0xff, 0xd8, 1, 2]));
      socket.add(
        jsonEncode(
          <String, Object?>{'type': 'url', 'url': 'http://localhost:3000/'},
        ),
      );
      socket.add(
        jsonEncode(<String, Object?>{'type': 'dialog', 'message': 'saved'}),
      );
    });
    final BrowserController controller = BrowserController(
      backend: _LocalBackendClient(Uri.parse('ws://127.0.0.1:${server.port}')),
    );
    final List<BrowserNotice> notices = <BrowserNotice>[];
    controller.onNotice = notices.add;
    addTearDown(() async {
      controller.dispose();
      await server.close(force: true);
    });
    final StreamIterator<Map<String, Object?>> messages =
        StreamIterator<Map<String, Object?>>(received.stream);
    Future<Map<String, Object?>> next() async {
      expect(await messages.moveNext(), isTrue);
      return messages.current;
    }

    // Laid out before the socket is ready: the size is sent once it is.
    controller.resize(width: 412.4, height: 800, scale: 2.625, mobile: true);
    await controller.connect();
    expect(await next(), <String, Object?>{
      'type': 'resize',
      'width': 412,
      'height': 800,
      'scale': 2.625,
      'mobile': true,
    });
    expect(controller.connected, isTrue);

    controller.navigate(' 3000/admin ');
    expect(
      await next(),
      <String, Object?>{'type': 'navigate', 'url': '3000/admin'},
    );
    controller.sendTouch('touchMove', <int, Offset>{4: const Offset(10, 20)});
    expect((await next())['points'], <Object?>[
      <String, Object?>{'id': 4, 'x': 10.0, 'y': 20.0},
    ]);

    expect(controller.frame.value, <int>[0xff, 0xd8, 1, 2]);
    expect(controller.url, 'http://localhost:3000/');
    expect(notices.single.kind, 'dialog');
    expect(notices.single.message, 'saved');
  });

  testWidgets('phones send touches and desktops send mouse clicks',
      (WidgetTester tester) async {
    final _RecordingController controller = _RecordingController();
    addTearDown(controller.dispose);
    Future<void> show() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        AppScope(
          controller: AppSettingsController(),
          child: MaterialApp(
            home: BrowserScreen(
              backend: _LocalBackendClient(Uri()),
              controller: controller,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await show();
    expect(controller.mobile, isTrue);
    await tester.dragFrom(const Offset(100, 300), const Offset(150, 0));
    expect(controller.events.first, 'touchStart');
    expect(controller.events, contains('touchMove'));
    expect(controller.events.last, 'touchEnd');
    expect(
      controller.events.where((String e) => e.startsWith('mouse')),
      isEmpty,
    );

    controller.events.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await show();
    expect(controller.mobile, isFalse);
    await tester.tapAt(const Offset(100, 300));
    expect(
      controller.events,
      <String>['mousePressed:left', 'mouseReleased:left'],
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('submitting while disconnected preserves typed text',
      (WidgetTester tester) async {
    final _RecordingController controller = _RecordingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: BrowserScreen(
            backend: _LocalBackendClient(Uri()),
            controller: controller,
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pump();
    final Finder input = find.byWidgetPredicate(
      (Widget widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'Type into the page',
    );
    await tester.enterText(input, 'keep this draft');

    controller.currentStatus = BrowserStatus.disconnected;
    controller.notifyListeners();
    await tester.pump();
    // The loading overlay says what the browser can open.
    expect(
      find.textContaining('only opens localhost and 127.0.0.1'),
      findsOneWidget,
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, 'keep this draft');
    expect(controller.events, isEmpty);

    controller.currentStatus = BrowserStatus.connected;
    controller.notifyListeners();
    await tester.pump();
    expect(
      find.textContaining('only opens localhost and 127.0.0.1'),
      findsNothing,
    );
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(controller.events, <String>['text:keep this draft']);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
  });
}

class _RecordingController extends BrowserController {
  _RecordingController() : super(backend: _LocalBackendClient(Uri()));

  final List<String> events = <String>[];
  bool? mobile;
  BrowserStatus currentStatus = BrowserStatus.connected;

  @override
  BrowserStatus get status => currentStatus;

  @override
  Future<void> connect() async {}

  @override
  void resize({
    required double width,
    required double height,
    required double scale,
    required bool mobile,
  }) {
    this.mobile = mobile;
  }

  @override
  void sendTouch(String event, Map<int, Offset> points) => events.add(event);

  @override
  void sendText(String text) => events.add('text:$text');

  @override
  void sendMouse(
    String event,
    Offset position, {
    String button = 'none',
    int buttons = 0,
    int clickCount = 0,
    Offset delta = Offset.zero,
  }) {
    events.add('$event:$button');
  }
}

class _LocalBackendClient extends BackendClient {
  _LocalBackendClient(this.uri);

  final Uri uri;

  @override
  Future<Uri> browserWebSocketUri() async => uri;
}
