import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/api_transport.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/core/storage/device_id_store.dart';
import 'package:relay_core/core/storage/workdir_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('each machine gets only its own workdir header', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    WorkdirStore.resetCacheForTest();
    final ApiTransport transport = ApiTransport(
      deviceIdStore: _FixedDeviceIdStore(),
    );
    final MachineCredential first = _machine('machine-1');
    final MachineCredential second = _machine('machine-2');

    await transport.writeWorkdir(first, '/home/pc/code/Relay');

    expect(
      (await transport.headers(first))['X-Workdir'],
      '/home/pc/code/Relay',
    );
    // A path on one host must not reach another, which would try to create it.
    expect((await transport.headers(second)).containsKey('X-Workdir'), isFalse);

    // Survives a restart (fresh cache, same stored preferences).
    WorkdirStore.resetCacheForTest();
    expect(await WorkdirStore().read('machine-1'), '/home/pc/code/Relay');
    expect(await WorkdirStore().read('machine-2'), isNull);
  });
}

MachineCredential _machine(String id) => MachineCredential(
      id: id,
      name: id,
      baseUrl: 'http://127.0.0.1:8787',
      token: 'token',
      createdAt: DateTime.utc(2026).toIso8601String(),
    );

class _FixedDeviceIdStore extends DeviceIdStore {
  @override
  Future<String> readOrCreate() async => 'device-test';
}
