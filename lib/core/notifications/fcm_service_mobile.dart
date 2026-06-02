import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../backend/backend_client.dart';
import 'notification_service.dart';

@pragma('vm:entry-point')
Future<void> agentDeckFcmBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {
    // No Firebase config is a supported deployment mode.
  }
}

class FcmService {
  FcmService._();

  static final FcmService instance = FcmService._();

  bool _initialized = false;
  bool _backgroundHandlerRegistered = false;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _foregroundSub;
  String? _registeredToken;
  String _lang = 'en';

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<bool> syncRegistration({
    required BackendClient backendClient,
    required String lang,
  }) async {
    if (!_supported) return true;
    _lang = lang == 'zh' ? 'zh' : 'en';
    try {
      _registerBackgroundHandler();
      final bool initialized = await _ensureInitialized();
      if (!initialized) return true;

      final NotificationSettings settings =
          await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        return true;
      }

      final String? token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return false;
      await backendClient.registerFcmToken(token, _lang);
      _registeredToken = token;
      _listenForTokenRefresh(backendClient);
      _listenForForegroundMessages();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> unregister(BackendClient backendClient) async {
    final String? token = _registeredToken;
    if (token == null || token.isEmpty) return;
    try {
      await backendClient.unregisterFcmToken(token);
      await FirebaseMessaging.instance.deleteToken();
      _registeredToken = null;
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  void _registerBackgroundHandler() {
    if (_backgroundHandlerRegistered) return;
    FirebaseMessaging.onBackgroundMessage(agentDeckFcmBackgroundHandler);
    _backgroundHandlerRegistered = true;
  }

  Future<bool> _ensureInitialized() async {
    if (_initialized) return true;
    try {
      await Firebase.initializeApp();
      _initialized = true;
      return true;
    } catch (_) {
      // Missing google-services.json is allowed; FCM stays disabled.
      return false;
    }
  }

  void _listenForTokenRefresh(BackendClient backendClient) {
    if (_tokenRefreshSub != null) return;
    _tokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen(
      (String token) {
        if (token.isEmpty) return;
        unawaited(
          backendClient.registerFcmToken(token, _lang).then((_) {
            _registeredToken = token;
          }).catchError((_) {}),
        );
      },
    );
  }

  void _listenForForegroundMessages() {
    if (_foregroundSub != null) return;
    _foregroundSub =
        FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final RemoteNotification? notification = message.notification;
      final String title = notification?.title ??
          message.data['title']?.toString() ??
          'AgentDeck';
      final String body =
          notification?.body ?? message.data['body']?.toString() ?? '';
      if (body.isEmpty) return;
      unawaited(
        NotificationService.instance.show(title: title, body: body),
      );
    });
  }
}
