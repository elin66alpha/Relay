import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/backend/demo_http_client.dart';
import 'package:relay_core/core/backend/sse_codec.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/models/cli_agent.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/core/storage/device_id_store.dart';
import 'package:relay_core/core/storage/machine_credentials_store.dart';
import 'package:relay_core/core/storage/workdir_store.dart';
import 'package:relay_core/features/chat/agent_controls.dart';
import 'package:relay_core/features/chat/bot_chat_controller.dart';
import 'package:relay_core/features/chat/bot_chat_screen.dart';
import 'package:relay_core/features/cli_agents/cli_agents_controller.dart';
import 'package:relay_core/features/machines/machine_credentials_controller.dart';
import 'package:relay_core/features/machines/machine_credentials_screen.dart';
import 'package:relay_core/features/machines/machine_details_screen.dart';
import 'package:relay_core/features/quota/quota_controller.dart';
import 'package:relay_core/features/settings/app_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MachineCredentialsStore.resetCacheForTest();
    DeviceIdStore.resetCacheForTest();
    WorkdirStore.resetCacheForTest();
  });

  group('DemoHttpClient', () {
    test('answers health, agents, and unknown route errors', () async {
      final DemoHttpClient client = DemoHttpClient(chunkDelay: Duration.zero);
      addTearDown(client.close);

      final http.Response health = await client.get(
        Uri.parse('$demoMachineBaseUrl/api/health'),
      );
      expect(health.statusCode, 200);
      expect(jsonDecode(health.body), <String, Object?>{'ok': true});

      final http.Response agents = await client.get(
        Uri.parse('$demoMachineBaseUrl/api/agents'),
      );
      expect(agents.statusCode, 200);
      final Map<String, Object?> decodedAgents =
          (jsonDecode(agents.body) as Map).cast<String, Object?>();
      final List<Object?> agentList = decodedAgents['agents']! as List<Object?>;
      expect(
        agentList.map((Object? item) => (item! as Map)['key']).toList(),
        <String>['claude', 'codex'],
      );
      expect(
        agentList.every((Object? item) => (item! as Map)['usable'] == true),
        isTrue,
      );

      final http.Response unknown = await client.get(
        Uri.parse('$demoMachineBaseUrl/api/not-a-route'),
      );
      expect(unknown.statusCode, 501);
      expect(
        jsonDecode(unknown.body),
        <String, Object?>{'error': 'Not available in demo mode'},
      );
    });

    test('unsupported streamed uploads finish with a demo error', () async {
      final DemoHttpClient client = DemoHttpClient();
      addTearDown(client.close);
      final http.StreamedRequest request = http.StreamedRequest(
        'POST',
        Uri.parse('$demoMachineBaseUrl/api/fs/upload'),
      );
      final Future<http.StreamedResponse> response = client.send(request);
      await request.sink.addStream(Stream<List<int>>.value(<int>[1, 2]));
      await request.sink.close().timeout(const Duration(seconds: 2));
      expect((await response).statusCode, 501);
    });

    test('streams fixed English and Chinese replies over SSE', () async {
      final DemoHttpClient enClient = DemoHttpClient(
        language: AppLanguage.en,
        chunkDelay: const Duration(milliseconds: 1),
      );
      addTearDown(enClient.close);

      final http.Request enReq = http.Request(
        'POST',
        Uri.parse('$demoMachineBaseUrl/api/chat'),
      )
        ..headers['Accept'] = 'text/event-stream'
        ..body = jsonEncode(<String, Object?>{
          'agent': 'claude',
          'sessionId': 'default',
          'requestId': 'req-en',
          'prompt': 'hi',
        });
      final http.StreamedResponse enResp = await enClient.send(enReq);
      expect(enResp.statusCode, 200);
      final List<BackendEvent> enEvents =
          await decodeSse(enResp.stream).toList();
      expect(enEvents.first.type, 'ready');
      final String enStreamed = enEvents
          .where((BackendEvent e) => e.type == 'agent_delta')
          .map((BackendEvent e) => e.data['text'] as String)
          .join();
      expect(enStreamed, DemoHttpClient.demoReplyEn);
      final BackendEvent enDone = enEvents.last;
      expect(enDone.type, 'agent_done');
      expect(
        (enDone.data['message']! as Map)['content'],
        DemoHttpClient.demoReplyEn,
      );

      final DemoHttpClient zhClient = DemoHttpClient(
        language: AppLanguage.zh,
        chunkDelay: const Duration(milliseconds: 1),
      );
      addTearDown(zhClient.close);

      final http.Request zhReq = http.Request(
        'POST',
        Uri.parse('$demoMachineBaseUrl/api/chat'),
      )
        ..headers['Accept'] = 'text/event-stream'
        ..body = jsonEncode(<String, Object?>{
          'agent': 'codex',
          'sessionId': 'default',
          'requestId': 'req-zh',
          'prompt': '你好',
        });
      final http.StreamedResponse zhResp = await zhClient.send(zhReq);
      final List<BackendEvent> zhEvents =
          await decodeSse(zhResp.stream).toList();
      final String zhStreamed = zhEvents
          .where((BackendEvent e) => e.type == 'agent_delta')
          .map((BackendEvent e) => e.data['text'] as String)
          .join();
      expect(zhStreamed, DemoHttpClient.demoReplyZh);
      expect(
        (zhEvents.last.data['message']! as Map)['content'],
        DemoHttpClient.demoReplyZh,
      );
    });

    test('BackendClient routes demo machine requests through DemoHttpClient',
        () async {
      final MachineCredential demo = demoMachineCredential();
      final BackendClient client = BackendClient(
        machine: demo,
        credentialsStore: _MemoryCredentialsStore(<MachineCredential>[demo]),
        deviceIdStore: _FixedDeviceIdStore(),
      );
      addTearDown(client.close);

      expect(await client.health(), isTrue);
      final List<CliAgent> agents = await client.fetchAgents();
      expect(agents.map((CliAgent a) => a.key), <String>['claude', 'codex']);
      expect((await client.workdir()).dir, '/home/demo/Relay');
      expect((await client.recentWorkdirs()), <String>['/home/demo/Relay']);
      expect((await client.fetchGroups()), isEmpty);
      expect(
        (await client.fetchHistory('claude', sessionId: 'default')).messages,
        isEmpty,
      );

      final List<String> deltas = <String>[];
      final ChatReply reply = await client.sendMessage(
        agentKey: 'claude',
        sessionId: 'default',
        prompt: 'hello',
        requestId: 'demo-req-1',
        onEvent: (BackendEvent event) {
          if (event.type == 'agent_delta') {
            deltas.add(event.data['text'] as String? ?? '');
          }
        },
      );
      expect(deltas.join(), DemoHttpClient.demoReplyEn);
      expect(reply.content, DemoHttpClient.demoReplyEn);

      // In-memory history persists, searches, exports, and clears cleanly.
      final ChatHistory history = await client.fetchHistory(
        'claude',
        sessionId: 'default',
      );
      expect(history.messages.length, 2);
      expect(history.messages.first.content, 'hello');
      expect(history.messages.last.content, DemoHttpClient.demoReplyEn);
      expect((await client.deviceTokens()), isEmpty);

      final List<ChatHistorySearchResult> hits =
          await client.searchHistory('hello', agentKey: 'claude');
      expect(hits.single.messageId, 'demo-req-1:user');
      final ConversationExport exported = await client.exportHistory(
        'claude',
        sessionId: 'default',
      );
      expect(exported.markdown, contains(DemoHttpClient.demoReplyEn));

      await client.clearSession('claude', 'default');
      expect(
        (await client.fetchHistory('claude', sessionId: 'default')).messages,
        isEmpty,
      );
    });

    test(
        'cancelling an active demo stream and pre-registration abort work cleanly',
        () async {
      final DemoHttpClient client = DemoHttpClient(
        language: AppLanguage.en,
        chunkDelay: const Duration(milliseconds: 20),
        chunkSize: 4,
      );
      addTearDown(client.close);

      final http.Client streamClient = client.createStreamClient();
      final http.Request req = http.Request(
        'POST',
        Uri.parse('$demoMachineBaseUrl/api/chat'),
      )
        ..headers['Accept'] = 'text/event-stream'
        ..body = jsonEncode(<String, Object?>{
          'agent': 'claude',
          'sessionId': 'default',
          'requestId': 'demo-cancel-1',
          'prompt': 'stop me',
        });
      final http.StreamedResponse resp = await streamClient.send(req);
      final List<BackendEvent> events = <BackendEvent>[];
      final Completer<void> sawDelta = Completer<void>();
      final Future<void> done =
          decodeSse(resp.stream).forEach((BackendEvent e) {
        events.add(e);
        if (e.type == 'agent_delta' && !sawDelta.isCompleted) {
          sawDelta.complete();
        }
      });
      await sawDelta.future;

      final http.Response cancelResp = await client.post(
        Uri.parse('$demoMachineBaseUrl/api/chat/cancel'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, Object?>{'requestId': 'demo-cancel-1'}),
      );
      expect(cancelResp.statusCode, 200);
      await done;
      expect(
        events.map((BackendEvent e) => e.type),
        contains('agent_cancelled'),
      );

      // Closing a stream client immediately prevents leaking an active turn.
      final http.Client abortedClient = client.createStreamClient();
      final http.Request abortedReq = http.Request(
        'POST',
        Uri.parse('$demoMachineBaseUrl/api/chat'),
      )
        ..headers['Accept'] = 'text/event-stream'
        ..body = jsonEncode(<String, Object?>{
          'agent': 'claude',
          'sessionId': 'default',
          'requestId': 'demo-abort-1',
          'prompt': 'abort early',
        });
      final Future<http.StreamedResponse> pending =
          abortedClient.send(abortedReq);
      abortedClient.close();
      await expectLater(pending, throwsA(isA<http.ClientException>()));
      final http.Response notFound = await client.post(
        Uri.parse('$demoMachineBaseUrl/api/chat/cancel'),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, Object?>{'requestId': 'demo-abort-1'}),
      );
      expect(notFound.statusCode, 404);
    });
  });

  testWidgets(
      'empty credential screen shows Try the demo, contact link, and enters demo mode',
      (WidgetTester tester) async {
    final UrlLauncherPlatform previousLauncher = UrlLauncherPlatform.instance;
    final _FakeLauncher launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = previousLauncher);

    final AppSettingsController settingsController = AppSettingsController();
    addTearDown(settingsController.dispose);
    await settingsController.load();
    final MachineCredentialsController machinesController =
        MachineCredentialsController(store: _MemoryCredentialsStore());
    await machinesController.load();

    await tester.pumpWidget(
      AppScope(
        controller: settingsController,
        child: MaterialApp(
          home: MachineCredentialsScreen(
            machinesController: machinesController,
            settingsController: settingsController,
            requireCredential: true,
          ),
        ),
      ),
    );

    expect(find.text('Try the demo'), findsOneWidget);
    const String contactEn =
        'Need a ready-made backend? Contact the author on GitHub';
    expect(find.text(contactEn), findsOneWidget);

    await tester.ensureVisible(find.text(contactEn));
    await tester.tap(find.text(contactEn));
    await tester.pumpAndSettle();
    expect(launcher.launched, <String>['https://github.com/elin66alpha']);

    // Switching language updates both labels to Chinese.
    await tester.ensureVisible(find.text('中/En'));
    await tester.tap(find.text('中/En'));
    await tester.pumpAndSettle();
    expect(find.text('试用演示'), findsOneWidget);
    expect(find.text('需要一台现成的后端？请在 GitHub 联系作者'), findsOneWidget);

    await tester.ensureVisible(find.text('试用演示'));
    await tester.tap(find.text('试用演示'));
    await tester.pumpAndSettle();
    expect(isDemoMachine(machinesController.activeMachine), isTrue);

    // Importing a real machine removes the demo machine.
    final MachineCredential real = MachineCredential(
      id: 'real-1',
      name: 'Workstation',
      baseUrl: 'https://relay.example.com',
      token: 'tok-real',
      createdAt: DateTime.utc(2026).toIso8601String(),
    );
    await machinesController.saveCredential(real);
    expect(
      machinesController.credentials.map((MachineCredential m) => m.id),
      <String>['real-1'],
    );
    expect(isDemoMachine(machinesController.activeMachine), isFalse);
  });

  testWidgets('About this app dialog shows the GitHub contact link', (
    WidgetTester tester,
  ) async {
    final UrlLauncherPlatform previousLauncher = UrlLauncherPlatform.instance;
    final _FakeLauncher launcher = _FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = previousLauncher);

    final AppSettingsController settingsController = AppSettingsController();
    addTearDown(settingsController.dispose);
    await settingsController.load();

    await tester.pumpWidget(
      AppScope(
        controller: settingsController,
        child: MaterialApp(
          home: AppSettingsScreen(settingsController: settingsController),
        ),
      ),
    );

    const String contactEn =
        'Need a ready-made backend? Contact the author on GitHub';
    expect(find.text(contactEn), findsNothing);

    await tester.ensureVisible(find.text('About this app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About this app'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(contactEn));
    await tester.pumpAndSettle();
    expect(launcher.launched, <String>['https://github.com/elin66alpha']);
  });

  testWidgets(
      'Demo mode banner exits demo and SSH/Browser entry points are disabled',
      (WidgetTester tester) async {
    final MachineCredential demo = demoMachineCredential();
    final _MemoryCredentialsStore store =
        _MemoryCredentialsStore(<MachineCredential>[demo]);
    final MachineCredentialsController machinesController =
        MachineCredentialsController(store: store);
    await machinesController.load();

    final AppSettingsController settingsController = AppSettingsController();
    addTearDown(settingsController.dispose);
    await settingsController.load();

    final CliAgentsController agentsController = CliAgentsController();
    await agentsController.load();

    final BackendClient backend = BackendClient(
      credentialsStore: store,
      deviceIdStore: _FixedDeviceIdStore(),
    );
    final BotChatController chatController = BotChatController(
      backendClient: backend,
      quotaController: QuotaController(backendClient: backend),
    );
    addTearDown(chatController.disposeController);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    int releaseChecks = 0;
    await tester.pumpWidget(
      AppScope(
        controller: settingsController,
        child: MaterialApp(
          home: BotChatScreen(
            latestVersion: () async {
              releaseChecks++;
              return '0.1.13';
            },
            agentsController: agentsController,
            chatController: chatController,
            machinesController: machinesController,
            settingsController: settingsController,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(releaseChecks, 0);
    expect(find.text('Demo mode'), findsOneWidget);
    expect(find.text('Exit demo'), findsOneWidget);

    // Open drawer and check Browser is disabled.
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browser'));
    await tester.pumpAndSettle();
    expect(find.text('Browser'), findsOneWidget);
    expect(find.text('CLI agents'), findsOneWidget);

    // Open Machine details from drawer and verify Enter SSH is disabled
    // and Device tokens loads cleanly without errors.
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('Relay Demo'),
      ),
    );
    await tester.pumpAndSettle();
    final FilledButton sshButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Enter SSH'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(sshButton.onPressed, isNull);
    await tester.scrollUntilVisible(
      find.text('No device tokens.'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('No device tokens.'), findsOneWidget);
    expect(find.textContaining('501'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Open Claude Code solo chat, send a prompt, and see the streamed reply.
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('Claude Code'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Demo mode'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hello demo');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(
      find.text(DemoHttpClient.demoReplyEn, findRichText: true),
      findsOneWidget,
    );

    // Switching to Codex and back keeps the in-memory Claude demo history.
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('Codex'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(DemoHttpClient.demoReplyEn, findRichText: true),
      findsNothing,
    );
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('Claude Code'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(DemoHttpClient.demoReplyEn, findRichText: true),
      findsOneWidget,
    );

    // Clear chat succeeds cleanly in Demo mode.
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    final attach = tester.widget<ComposerActionButton>(
      find.widgetWithText(ComposerActionButton, 'Attach file'),
    );
    expect(attach.onPressed, isNull);
    await tester.tap(find.text('Clear chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(
      find.text(DemoHttpClient.demoReplyEn, findRichText: true),
      findsNothing,
    );
    expect(find.textContaining('501'), findsNothing);

    // Tap Exit demo on the banner and confirm demo machine is deleted.
    await tester.tap(find.text('Exit demo'));
    await tester.pumpAndSettle();
    expect(machinesController.activeMachine, isNull);
    expect(machinesController.credentials, isEmpty);
  });

  testWidgets(
      'Demo MachineDetailsScreen hides backend update offer even with newer release',
      (WidgetTester tester) async {
    final MachineCredential demo = demoMachineCredential();
    final BackendClient backend = BackendClient(
      machine: demo,
      credentialsStore: _MemoryCredentialsStore(<MachineCredential>[demo]),
      deviceIdStore: _FixedDeviceIdStore(),
    );
    addTearDown(backend.close);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: MachineDetailsScreen(
            machine: demo,
            backend: backend,
            agentsController: CliAgentsController(),
            latestVersion: () async => '0.99.0',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Demo Virtual CPU · 8 threads'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('No device tokens.'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('No device tokens.'), findsOneWidget);
    expect(find.text('Update to 0.99.0 and restart'), findsNothing);
    expect(find.textContaining('501'), findsNothing);
  });

  testWidgets('Chinese Demo mode streams localized reply in solo chat', (
    WidgetTester tester,
  ) async {
    final MachineCredential demo = demoMachineCredential();
    final _MemoryCredentialsStore store =
        _MemoryCredentialsStore(<MachineCredential>[demo]);
    final MachineCredentialsController machinesController =
        MachineCredentialsController(store: store);
    await machinesController.load();

    final AppSettingsController settingsController = AppSettingsController();
    addTearDown(settingsController.dispose);
    await settingsController.setLanguage(AppLanguage.zh);

    final CliAgentsController agentsController = CliAgentsController();
    await agentsController.load();

    final BackendClient backend = BackendClient(
      credentialsStore: store,
      deviceIdStore: _FixedDeviceIdStore(),
    );
    final BotChatController chatController = BotChatController(
      backendClient: backend,
      quotaController: QuotaController(backendClient: backend),
    );
    addTearDown(chatController.disposeController);

    await tester.pumpWidget(
      AppScope(
        controller: settingsController,
        child: MaterialApp(
          home: BotChatScreen(
            agentsController: agentsController,
            chatController: chatController,
            machinesController: machinesController,
            settingsController: settingsController,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('演示模式'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('Claude Code'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '你好演示');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(
      find.text(DemoHttpClient.demoReplyZh, findRichText: true),
      findsOneWidget,
    );
  });
}

class _FixedDeviceIdStore extends DeviceIdStore {
  @override
  Future<String> readOrCreate() async => 'device-demo-test';
}

class _MemoryCredentialsStore extends MachineCredentialsStore {
  _MemoryCredentialsStore([List<MachineCredential> initial = const []])
      : _items = List<MachineCredential>.of(initial),
        _activeId = initial.isEmpty ? null : initial.first.id;

  final List<MachineCredential> _items;
  String? _activeId;

  @override
  Future<List<MachineCredential>> readAll() async =>
      List<MachineCredential>.of(_items);

  @override
  Future<String?> readActiveId() async => _activeId;

  @override
  Future<void> setActive(String id) async {
    _activeId = id;
  }

  @override
  Future<void> upsert(
    MachineCredential credential, {
    bool makeActive = true,
  }) async {
    if (!isDemoMachine(credential)) {
      _items.removeWhere(isDemoMachine);
    }
    _items.removeWhere((MachineCredential item) => item.id == credential.id);
    _items.add(credential);
    if (makeActive) _activeId = credential.id;
  }

  @override
  Future<void> delete(String id) async {
    _items.removeWhere((MachineCredential item) => item.id == id);
    if (_activeId == id) {
      _activeId = _items.isEmpty ? null : _items.first.id;
    }
  }
}

class _FakeLauncher extends UrlLauncherPlatform {
  final List<String> launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}
