import 'browser_notifications_stub.dart'
    if (dart.library.html) 'browser_notifications_web.dart' as platform;

Future<void> requestBrowserNotificationPermission() =>
    platform.requestBrowserNotificationPermission();

Future<bool> showBrowserNotification({
  required String title,
  required String body,
}) =>
    platform.showBrowserNotification(title: title, body: body);
