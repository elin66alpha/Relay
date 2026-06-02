import 'dart:js_interop';

// Bound to window.agentdeckPush.* defined in web/push_interop.js. That helper
// owns the service-worker registration and PushManager subscribe so this Dart
// layer stays a thin bridge.

@JS('agentdeckPush.supported')
external bool _supported();

@JS('agentdeckPush.subscribe')
external JSPromise<JSString?> _subscribe(JSString vapidKey);

@JS('agentdeckPush.unsubscribe')
external JSPromise<JSString?> _unsubscribe();

bool webPushSupported() {
  try {
    return _supported();
  } catch (_) {
    return false;
  }
}

Future<String?> webPushSubscribe(String vapidPublicKey) async {
  try {
    final JSString? result = await _subscribe(vapidPublicKey.toJS).toDart;
    return result?.toDart;
  } catch (_) {
    return null;
  }
}

Future<String?> webPushUnsubscribe() async {
  try {
    final JSString? result = await _unsubscribe().toDart;
    return result?.toDart;
  } catch (_) {
    return null;
  }
}
