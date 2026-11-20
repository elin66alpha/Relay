import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/models/cli_agent.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/core/storage/device_id_store.dart';
import 'package:relay_core/core/storage/machine_credentials_store.dart';
import 'package:relay_core/features/chat/bot_chat_controller.dart';
import 'package:relay_core/features/chat/bot_chat_screen.dart';
import 'package:relay_core/features/cli_agents/cli_agents_controller.dart';
import 'package:relay_core/features/machines/machine_credentials_controller.dart';
import 'package:relay_core/features/quota/quota_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Five hosts behind one app, each reporting its own Claude quota so the strip
// shows which host's numbers it holds.
const int _machineCount = 5;

void main() {
  testWidgets('switching machines shows each host\'s own quota strip', (
    WidgetTester tester,
  ) async {
    final _Hosts hosts = _Hosts();
    final MachineCredentialsController machines = await _openChat(
      tester,
      hosts,
    );
    expect(find.text('10%'), findsOneWidget);

    for (final int n in <int>[2, 3, 4, 5, 1]) {
      await machines.setActive('m$n');
      await _settle(tester);
      expect(find.text('${n * 10}%'), findsOneWidget, reason: 'machine m$n');
    }
    await _close(tester);
  });

  testWidgets('a quota reply from the previous machine is not shown', (
    WidgetTester tester,
  ) async {
    final _Hosts hosts = _Hosts();
    final MachineCredentialsController machines = await _openChat(
      tester,
      hosts,
    );
    // m1 is slow: its next quota reply arrives after the switch to m2.
    final Completer<void> m1Reply = Completer<void>();
    hosts.holdUsage['m1.test'] = m1Reply.future;
    await machines.setActive('m2');
    await _settle(tester);
    await machines.setActive('m1');
    await tester.pump();
    await machines.setActive('m2');
    await _settle(tester);
    m1Reply.complete();
    await _settle(tester);

    expect(find.text('20%'), findsOneWidget);
    expect(find.text('10%'), findsNothing);
    // The late m1 reply did not overwrite m2's numbers either, so the next
    // repaint still shows m2.
    final UsageQuota quota =
        _chat!.quotaController.lastUsageReport!.agents.single.quotas.single;
    expect(quota.remainingPercent, 20);
    await _close(tester);
  });

  testWidgets('a switch sends each request once, to the new host only', (
    WidgetTester tester,
  ) async {
    final _Hosts hosts = _Hosts();
    final MachineCredentialsController machines = await _openChat(
      tester,
      hosts,
    );
    hosts.requests.clear();
    await machines.setActive('m2');
    await _settle(tester);

    final Map<String, int> paths = <String, int>{};
    for (final Uri uri in hosts.requests) {
      expect(uri.host, 'm2.test', reason: '$uri');
      paths.update(uri.path, (int n) => n + 1, ifAbsent: () => 1);
    }
    // The live event stream and the quota strip follow the new host.
    expect(paths['/api/events'], 1, reason: '$paths');
    expect(paths['/api/usage'], 1, reason: '$paths');
    expect(paths['/api/history'], 1, reason: '$paths');
    await _close(tester);
  });

  test('a switch reuses the stored credential list', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MachineCredentialsStore.resetCacheForTest();
    final _CountingSecureStorage storage = _CountingSecureStorage(
      jsonEncode(<Object?>[
        for (int n = 1; n <= _machineCount; n += 1) _machine(n).toJson(),
      ]),
    );
    final MachineCredentialsStore store =
        MachineCredentialsStore(secureStorage: storage);
    // Requests that start together share one storage read.
    await Future.wait(<Future<Object?>>[
      for (int i = 0; i < 8; i += 1) store.readActive(),
    ]);
    expect(storage.reads, 1);

    await store.setActive('m2');
    final List<MachineCredential?> active = await Future.wait(
      <Future<MachineCredential?>>[
        for (int i = 0; i < 8; i += 1) store.readActive(),
      ],
    );
    expect(active.map((MachineCredential? m) => m?.id).toSet(), <String>{'m2'});
    expect(storage.reads, 1);
    MachineCredentialsStore.resetCacheForTest();
  });
}

MachineCredential _machine(int n) => MachineCredential(
      id: 'm$n',
      name: 'Machine $n',
      baseUrl: 'http://m$n.test',
      token: 'token-$n',
      createdAt: DateTime.utc(2026).toIso8601String(),
    );

/// Answers every host with a minimal backend; records each request.
class _Hosts {
  final List<Uri> requests = <Uri>[];
  final Map<String, Future<void>> holdUsage = <String, Future<void>>{};
  final List<StreamController<List<int>>> _events =
      <StreamController<List<int>>>[];

  late final http.Client client = MockClient.streaming((
    http.BaseRequest request,
    http.ByteStream body,
  ) async {
    final Uri uri = request.url;
    requests.add(uri);
    final int n = int.parse(uri.host.substring(1, 2));
    if (uri.path == '/api/events') {
      final StreamController<List<int>> events = StreamController<List<int>>();
      _events.add(events);
      return http.StreamedResponse(events.stream, 200);
    }
    if (uri.path == '/api/usage') {
      final Future<void>? hold = holdUsage.remove(uri.host);
      if (hold != null) await hold;
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(_reply(uri, n)))),
      200,
    );
  });

  Object? _reply(Uri uri, int n) {
    switch (uri.path) {
      case '/api/agents':
        return <String, Object?>{
          'agents': <Object?>[
            for (final CliAgent agent in defaultCliAgents)
              <String, Object?>{
                'key': agent.key,
                'label': agent.label,
                'installed': true,
                'authed': true,
                'usable': true,
              },
          ],
        };
      case '/api/usage':
        return <String, Object?>{
          'agents': <Object?>[
            <String, Object?>{
              'key': 'claude',
              'label': 'Claude Code',
              'available': true,
              'quotas': <Object?>[
                <String, Object?>{
                  'key': 'five_hour',
                  'label': '5h',
                  'remainingPercent': n * 10,
                },
              ],
            },
          ],
        };
      case '/api/history':
        return <String, Object?>{'messages': <Object?>[]};
      default:
        return <String, Object?>{};
    }
  }

  void close() {
    for (final StreamController<List<int>> events in _events) {
      unawaited(events.close());
    }
  }
}

Future<MachineCredentialsController> _openChat(
  WidgetTester tester,
  _Hosts hosts,
) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  MachineCredentialsStore.resetCacheForTest();
  final _MemoryStore store = _MemoryStore(<MachineCredential>[
    for (int n = 1; n <= _machineCount; n += 1) _machine(n),
  ]);
  final MachineCredentialsController machines =
      MachineCredentialsController(store: store);
  final BackendClient backend = BackendClient(
    credentialsStore: store,
    deviceIdStore: _FixedDeviceIdStore(),
    httpClient: hosts.client,
  );
  final CliAgentsController agents = CliAgentsController();
  final AppSettingsController settings = AppSettingsController();
  final BotChatController chat = BotChatController(
    backendClient: backend,
    quotaController: QuotaController(backendClient: backend),
  );
  addTearDown(hosts.close);
  addTearDown(chat.disposeController);
  _chat = chat;

  await agents.load();
  await machines.load();
  await chat.loadFor(defaultCliAgents.first, machines.activeMachine!);

  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    AppScope(
      controller: settings,
      child: MaterialApp(
        home: BotChatScreen(
          agentsController: agents,
          chatController: chat,
          machinesController: machines,
          settingsController: settings,
        ),
      ),
    ),
  );
  await _settle(tester);
  return machines;
}

// Spinners never settle, so advance a fixed stretch of fake time instead.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 20; i += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

BotChatController? _chat;

Future<void> _close(WidgetTester tester) async {
  // The open event stream holds an idle timer; close it before the test ends.
  // Its cancel completes only as fake time advances, so do not await it here.
  unawaited(_chat?.disconnectEvents());
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(minutes: 1));
}

class _MemoryStore extends MachineCredentialsStore {
  _MemoryStore(this.machines);

  final List<MachineCredential> machines;
  String? _activeId;

  @override
  Future<List<MachineCredential>> readAll() async => machines;

  @override
  Future<String?> readActiveId() async => _activeId ??= machines.first.id;

  @override
  Future<void> setActive(String id) async => _activeId = id;
}

class _FixedDeviceIdStore extends DeviceIdStore {
  @override
  Future<String> readOrCreate() async => 'device-test';
}

class _CountingSecureStorage extends FlutterSecureStorage {
  _CountingSecureStorage(this.value);

  final String value;
  int reads = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads += 1;
    // A real read is a platform call; overlap is what the cache must absorb.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return value;
  }
}
