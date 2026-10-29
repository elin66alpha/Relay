// Non-web stub: Web Push is a browser-only feature. Native platforms deliver
// quota alerts through flutter_local_notifications instead.
bool webPushSupported() => false;

Future<String?> webPushSubscribe(String vapidPublicKey) async => null;

Future<String?> webPushUnsubscribe() async => null;
