import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Wraps the OS notification tray so alerts (e.g. quota resets) surface as native
/// system notifications instead of cluttering the chat message list.
///
/// Only immediate notifications are used (`show`); there is no scheduling, so the
/// `timezone` setup that flutter_local_notifications needs for zoned schedules is
/// intentionally skipped. Uses [defaultTargetPlatform] rather than `dart:io` so
/// the import stays web-compile-safe for the future Web shell.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  int _nextId = 0;

  static const String _channelId = 'quota_alerts';
  static const String _channelName = 'Quota alerts';
  static const String _channelDescription =
      'CLI agent quota resets and usage warnings';

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Initialise the plugin and (on Android) create the notification channel.
  /// Safe to call repeatedly and on unsupported platforms.
  Future<void> init() async {
    if (_initialized || !_supported) {
      _initialized = true;
      return;
    }
    const AndroidInitializationSettings android =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: darwin,
        macOS: darwin,
      ),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDescription,
            importance: Importance.high,
          ),
        );
    _initialized = true;
  }

  /// Ask the user for notification permission (Android 13+ / iOS / macOS).
  Future<void> requestPermission() async {
    if (!_supported) return;
    await init();
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } else {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  /// Show an immediate system notification. No-op on unsupported platforms.
  Future<void> show({required String title, required String body}) async {
    if (!_supported) return;
    await init();
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
    );
    const DarwinNotificationDetails darwinDetails = DarwinNotificationDetails();
    await _plugin.show(
      id: _nextId++,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
      ),
    );
  }
}
