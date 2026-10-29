import '../../core/backend/backend_client.dart';
import '../../core/notifications/fcm_service.dart';
import '../../core/notifications/web_push.dart';

class ChatPushRegistration {
  ChatPushRegistration({
    required BackendClient backendClient,
    required this.hasMachine,
    required this.language,
    required this.quotaPushEnabled,
    required this.taskPushEnabled,
  }) : _backendClient = backendClient;

  final BackendClient _backendClient;
  final bool Function() hasMachine;
  final String Function() language;
  final bool Function() quotaPushEnabled;
  final bool Function() taskPushEnabled;

  bool get webPushActive => _webPushActive;

  void invalidatePreferences() {
    _pushSynced = false;
    _fcmSynced = false;
  }

  // Registers this browser for Web Push so quota/scheduled-message alerts arrive
  // even when the tab is closed. Web-only and best-effort: a no-op off the web,
  // when the backend has no VAPID keys, or until the user grants permission
  // (retried on the next app open). Runs at most once per session.
  bool _pushSynced = false;
  // Set only once a subscription is registered with the backend, so it means
  // "push will reach this browser" rather than "we finished trying".
  bool _webPushActive = false;
  Future<void> syncPushSubscription({bool force = false}) async {
    if ((!force && _pushSynced) || !hasMachine() || !webPushSupported()) {
      return;
    }
    try {
      final PushConfig config = await _backendClient.pushConfig();
      if (!config.enabled || config.publicKey.isEmpty) {
        _pushSynced = true;
        return;
      }
      final String? subscription = await webPushSubscribe(config.publicKey);
      if (subscription == null) return; // permission not granted yet
      await _backendClient.subscribePush(
        subscription,
        language(),
        quotaPushEnabled: quotaPushEnabled(),
        taskPushEnabled: taskPushEnabled(),
      );
      _pushSynced = true;
      _webPushActive = true;
    } catch (_) {
      // Best-effort; the next app open retries.
    }
  }

  // Registers this mobile device for FCM so quota/scheduled-message alerts can
  // arrive while the app is backgrounded or killed. Android/iOS only and
  // best-effort; web/desktop and missing Firebase config are no-ops.
  bool _fcmSynced = false;
  Future<void> syncFcmRegistration({bool force = false}) async {
    if ((!force && _fcmSynced) || !hasMachine()) return;
    try {
      final bool handled = await FcmService.instance.syncRegistration(
        backendClient: _backendClient,
        lang: language(),
        quotaPushEnabled: quotaPushEnabled(),
        taskPushEnabled: taskPushEnabled(),
      );
      if (handled) _fcmSynced = true;
    } catch (_) {
      // Best-effort; the next app open retries.
    }
  }
}
