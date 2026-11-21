import '../../core/backend/backend_client.dart';
import '../../core/notifications/fcm_service.dart';
import '../../core/notifications/web_push.dart';

typedef FcmSync = Future<bool> Function({
  required BackendClient backendClient,
  required String lang,
  required bool quotaPushEnabled,
  required bool taskPushEnabled,
});

class ChatPushRegistration {
  ChatPushRegistration({
    required BackendClient backendClient,
    required this.machineId,
    required this.language,
    required this.quotaPushEnabled,
    required this.taskPushEnabled,
    FcmSync? fcmSync,
  })  : _backendClient = backendClient,
        _fcmSync = fcmSync ?? FcmService.instance.syncRegistration;

  final BackendClient _backendClient;
  final FcmSync _fcmSync;

  /// The machine requests go to, or null when there is none to register with.
  final String? Function() machineId;
  final String Function() language;
  final bool Function() quotaPushEnabled;
  final bool Function() taskPushEnabled;

  bool get webPushActive => _webPushActive;

  void invalidatePreferences() {
    _pushSyncedFor = null;
    _fcmSyncedFor = null;
  }

  // Each backend keeps its own subscriptions, so registration runs once per
  // machine per session: a machine is registered when it becomes active.
  // shortcut: an FCM token refresh reaches only the active machine; the others
  // get the new token the next time they are active.

  // Registers this browser for Web Push so quota/scheduled-message alerts arrive
  // even when the tab is closed. Web-only and best-effort: a no-op off the web,
  // when the backend has no VAPID keys, or until the user grants permission
  // (retried on the next app open).
  String? _pushSyncedFor;
  // Set only once a subscription is registered with the active machine, so it
  // means "push will reach this browser" rather than "we finished trying".
  bool _webPushActive = false;
  Future<void> syncPushSubscription({bool force = false}) async {
    final String? machine = machineId();
    if (machine == null ||
        (!force && _pushSyncedFor == machine) ||
        !webPushSupported()) {
      return;
    }
    if (_pushSyncedFor != machine) _webPushActive = false;
    try {
      final PushConfig config = await _backendClient.pushConfig();
      if (!config.enabled || config.publicKey.isEmpty) {
        _pushSyncedFor = machine;
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
      _pushSyncedFor = machine;
      _webPushActive = machineId() == machine;
    } catch (_) {
      // Best-effort; the next app open retries.
    }
  }

  // Registers this mobile device for FCM so quota/scheduled-message alerts can
  // arrive while the app is backgrounded or killed. Android/iOS only and
  // best-effort; web/desktop and missing Firebase config are no-ops.
  String? _fcmSyncedFor;
  Future<void> syncFcmRegistration({bool force = false}) async {
    final String? machine = machineId();
    if (machine == null || (!force && _fcmSyncedFor == machine)) return;
    try {
      final bool handled = await _fcmSync(
        backendClient: _backendClient,
        lang: language(),
        quotaPushEnabled: quotaPushEnabled(),
        taskPushEnabled: taskPushEnabled(),
      );
      if (handled) _fcmSyncedFor = machine;
    } catch (_) {
      // Best-effort; the next app open retries.
    }
  }
}
