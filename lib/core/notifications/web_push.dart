import 'web_push_stub.dart'
    if (dart.library.html) 'web_push_web.dart' as platform;

/// Whether this platform can register for Web Push (true only on supported web
/// browsers). Non-web platforms use [NotificationService] instead.
bool webPushSupported() => platform.webPushSupported();

/// Subscribes the browser to Web Push using [vapidPublicKey] and returns the
/// subscription as a JSON string the backend can store, or null when
/// unsupported or permission was not granted.
Future<String?> webPushSubscribe(String vapidPublicKey) =>
    platform.webPushSubscribe(vapidPublicKey);

/// Removes the current Web Push subscription and returns the removed endpoint,
/// or null when there was none.
Future<String?> webPushUnsubscribe() => platform.webPushUnsubscribe();
