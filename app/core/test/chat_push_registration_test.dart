import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/features/chat/chat_push_registration.dart';

void main() {
  test('registers push with each machine the device switches to', () async {
    String? machine = 'studio';
    final List<String?> registered = <String?>[];
    final ChatPushRegistration push = ChatPushRegistration(
      backendClient: BackendClient(),
      machineId: () => machine,
      language: () => 'en',
      quotaPushEnabled: () => true,
      taskPushEnabled: () => true,
      fcmSync: ({
        required BackendClient backendClient,
        required String lang,
        required bool quotaPushEnabled,
        required bool taskPushEnabled,
      }) async {
        registered.add(machine);
        return true;
      },
    );

    await push.syncFcmRegistration();
    await push.syncFcmRegistration();
    expect(registered, <String>['studio']);

    // A machine imported or switched to later in the session.
    machine = 'laptop';
    await push.syncFcmRegistration();
    expect(registered, <String>['studio', 'laptop']);

    // No machine (or the demo): nothing to register with.
    machine = null;
    await push.syncFcmRegistration();
    expect(registered, <String>['studio', 'laptop']);

    // Changed notification preferences re-register the active machine.
    machine = 'laptop';
    push.invalidatePreferences();
    await push.syncFcmRegistration();
    expect(registered, <String>['studio', 'laptop', 'laptop']);
  });
}
