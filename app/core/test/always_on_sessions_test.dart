import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/backend/demo_http_client.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/models/agent_session.dart';
import 'package:relay_core/core/models/chat_message.dart';
import 'package:relay_core/core/models/cli_agent.dart';
import 'package:relay_core/core/models/group.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/core/storage/device_id_store.dart';
import 'package:relay_core/features/chat/bot_chat_controller.dart';
import 'package:relay_core/features/chat/bot_chat_screen.dart';
import 'package:relay_core/features/chat/home_navigation_page.dart';
import 'package:relay_core/features/cli_agents/cli_agents_controller.dart';
import 'package:relay_core/features/machines/machine_credentials_controller.dart';
import 'package:relay_core/features/quota/quota_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

final MachineCredential _machine = MachineCredential(
  id: 'm1',
  name: 'Workstation',
  baseUrl: 'http://127.0.0.1:8787',
  token: 'test-token',
  createdAt: DateTime.utc(2026).toIso8601String(),
);

void main() {
  test('BackendClient treats 404 as unsupported and maps 409 ALWAYS_ON_LIMIT',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    int status = 404;
    String body = '{"error":"not found"}';
    final BackendClient client = BackendClient(
      machine: _machine,
      deviceIdStore: _FixedDeviceIdStore(),
      httpClient: MockClient((http.Request req) async {
        return http.Response(body, status);
      }),
    );
    addTearDown(client.close);

    expect(await client.fetchAlwaysOnSessions(), isNull);

    body = '<pre>Cannot GET /api/sessions/always-on</pre>';
    expect(await client.fetchAlwaysOnSessions(), isNull);

    status = 409;
    body = jsonEncode(const <String, Object?>{
      'error': 'always-on limit reached (max 3)',
      'code': 'ALWAYS_ON_LIMIT',
    });
    await expectLater(
      client.setSessionAlwaysOn('claude', 'default', true),
      throwsA(
        isA<BackendException>()
            .having((BackendException e) => e.status, 'status', 409)
            .having(
              (BackendException e) => e.code,
              'code',
              'ALWAYS_ON_LIMIT',
            ),
      ),
    );
  });

  test('DemoHttpClient supports always-on routes in memory with cap of 3',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final DemoHttpClient demo = DemoHttpClient();
    final BackendClient client = BackendClient(
      machine: _machine,
      deviceIdStore: _FixedDeviceIdStore(),
      httpClient: demo,
    );
    addTearDown(client.close);

    final AlwaysOnSessionList? initial = await client.fetchAlwaysOnSessions();
    expect(initial, isNotNull);
    expect(initial!.max, 3);
    expect(initial.sessions, isEmpty);

    final AlwaysOnSessionList pinned =
        await client.setSessionAlwaysOn('claude', 'default', true);
    expect(pinned.sessions.length, 1);
    expect(pinned.sessions.first.agentKey, 'claude');
    expect(pinned.sessions.first.sessionId, 'default');

    await client.setSessionAlwaysOn('codex', 'default', true);
    await client.setSessionAlwaysOn('claude', 's2', true);

    await expectLater(
      client.setSessionAlwaysOn('claude', 's3', true),
      throwsA(
        isA<BackendException>().having(
          (BackendException e) => e.code,
          'code',
          'ALWAYS_ON_LIMIT',
        ),
      ),
    );

    final AlwaysOnSessionList afterRemove = await client.removeAlwaysOnSession(
      'claude',
      pinned.sessions.first.workdir,
      'default',
    );
    expect(afterRemove.sessions.length, 2);
  });

  testWidgets(
      'header toggle pins/unpins session, shows exact limit SnackBar, and hides on 404',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _AlwaysOnBackend backend = _AlwaysOnBackend();
    final _SingleMachineController machines = _SingleMachineController();
    final CliAgentsController agents = CliAgentsController();
    final AppSettingsController settings = AppSettingsController();
    final BotChatController chat = BotChatController(
      backendClient: backend,
      quotaController: QuotaController(backendClient: backend),
    );
    addTearDown(chat.disposeController);
    addTearDown(machines.dispose);
    addTearDown(agents.dispose);
    addTearDown(settings.dispose);

    await settings.setLanguage(AppLanguage.en);
    await chat.loadFor(defaultCliAgents.first, _machine);

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
            latestVersion: () async => '0.0.0',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Off initially -> outlined pin button immediately left of search.
    final Finder pinOutlined = find.byIcon(Icons.push_pin_outlined);
    final Finder searchIcon = find.byIcon(Icons.search_rounded);
    expect(pinOutlined, findsOneWidget);
    expect(searchIcon, findsOneWidget);
    expect(
      tester.getCenter(pinOutlined).dx,
      lessThan(tester.getCenter(searchIcon).dx),
    );

    // Toggle ON -> calls backend and updates to filled pin.
    await tester.tap(pinOutlined);
    await tester.pumpAndSettle();
    expect(backend.setCalls, <(String, String, bool)>[
      ('claude', 'default', true),
    ]);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);

    // Toggle OFF -> calls backend and updates back to outlined pin.
    await tester.tap(find.byIcon(Icons.push_pin));
    await tester.pumpAndSettle();
    expect(backend.setCalls.last, ('claude', 'default', false));
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);

    // Limit reached -> shows the exact SnackBar text (English).
    backend.failWithLimit = true;
    await tester.tap(find.byIcon(Icons.push_pin_outlined));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Always-on sessions are full (max 3). Go to Home and turn one off first.',
      ),
      findsOneWidget,
    );

    // Switch to Chinese -> shows the exact Chinese SnackBar text.
    ScaffoldMessenger.of(
      tester.element(find.byType(BotChatScreen)),
    ).clearSnackBars();
    await settings.setLanguage(AppLanguage.zh);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.push_pin_outlined));
    await tester.pumpAndSettle();
    expect(
      find.text('常驻会话已满（最多 3 个），不能再开启。请到首页取消一个常驻会话。'),
      findsOneWidget,
    );

    // Against an older backend answering 404 (unsupported) -> pin is hidden.
    backend.unsupported = true;
    await chat.refreshAlwaysOnSessions(machineId: _machine.id);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
    expect(find.byIcon(Icons.push_pin), findsNothing);
    await chat.disconnectEvents();
  });

  testWidgets('desktop header renders pin button immediately left of search',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _AlwaysOnBackend backend = _AlwaysOnBackend();
    final _SingleMachineController machines = _SingleMachineController();
    final CliAgentsController agents = CliAgentsController();
    final AppSettingsController settings = AppSettingsController();
    final BotChatController chat = BotChatController(
      backendClient: backend,
      quotaController: QuotaController(backendClient: backend),
    );
    addTearDown(chat.disposeController);
    addTearDown(machines.dispose);
    addTearDown(agents.dispose);
    addTearDown(settings.dispose);

    await settings.setLanguage(AppLanguage.en);
    await chat.loadFor(defaultCliAgents.first, _machine);

    tester.view.physicalSize = const Size(1280, 844);
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
            latestVersion: () async => '0.0.0',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder pin = find.byIcon(Icons.push_pin_outlined);
    final Finder search = find.byIcon(Icons.search_rounded);
    expect(pin, findsOneWidget);
    expect(search, findsOneWidget);
    expect(tester.getCenter(pin).dx, lessThan(tester.getCenter(search).dx));
    await chat.disconnectEvents();
  });

  testWidgets(
      'Home section lists always-on sessions, unpins via trailing button, and opens conversation on tap',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _AlwaysOnBackend backend = _AlwaysOnBackend(
      initialAlwaysOn: <AlwaysOnSession>[
        const AlwaysOnSession(
          agentKey: 'claude',
          workdir: '/proj/one',
          sessionId: 'default',
          name: 'Main',
        ),
        const AlwaysOnSession(
          agentKey: 'codex',
          workdir: '/proj/two',
          sessionId: 'sess-2',
          name: 'Refactor API',
        ),
      ],
    );
    final _SingleMachineController machines = _SingleMachineController();
    final CliAgentsController agents = CliAgentsController();
    final AppSettingsController settings = AppSettingsController();
    final BotChatController chat = BotChatController(
      backendClient: backend,
      quotaController: QuotaController(backendClient: backend),
    );
    addTearDown(chat.disposeController);
    addTearDown(machines.dispose);
    addTearDown(agents.dispose);
    addTearDown(settings.dispose);

    await settings.setLanguage(AppLanguage.en);

    await tester.pumpWidget(
      AppScope(
        controller: settings,
        child: MaterialApp(
          home: Scaffold(
            body: HomeNavigationPage(
              agentsController: agents,
              chatController: chat,
              machinesController: machines,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Section appears below Recent workspaces and lists both pinned sessions.
    expect(find.text('Always-on sessions'), findsOneWidget);
    expect(find.text('Main'), findsOneWidget);
    expect(find.text('one · Claude Code'), findsOneWidget);
    expect(find.text('Refactor API'), findsOneWidget);
    expect(find.text('two · Codex'), findsOneWidget);

    // Trailing button removes the first always-on session and refreshes.
    final Finder removeMain = find.descendant(
      of: find.widgetWithText(ListTile, 'Main'),
      matching: find.byIcon(Icons.push_pin),
    );
    await tester.tap(removeMain);
    await tester.pumpAndSettle();
    expect(backend.removedCalls, <(String, String, String)>[
      ('claude', '/proj/one', 'default'),
    ]);
    expect(find.text('Main'), findsNothing);
    expect(find.text('Refactor API'), findsOneWidget);

    // Tapping the remaining row switches workdir, agent, and session.
    await tester.tap(find.text('Refactor API'));
    await tester.pumpAndSettle();
    expect(backend.selectedWorkdirs, <String>['/proj/two']);
    expect(agents.activeAgentKey, 'codex');
    expect(chat.machine?.id, _machine.id);
    expect(chat.agent.key, 'codex');
    expect(chat.activeWorkdir, '/proj/two');
    expect(chat.activeSessionId, 'sess-2');
    expect(backend.selectedSessions, <(String, String)>[('codex', 'sess-2')]);
  });

  testWidgets('Home section shows empty text when supported and hidden on 404',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _AlwaysOnBackend backend = _AlwaysOnBackend();
    final _SingleMachineController machines = _SingleMachineController();
    final CliAgentsController agents = CliAgentsController();
    final AppSettingsController settings = AppSettingsController();
    final BotChatController chat = BotChatController(
      backendClient: backend,
      quotaController: QuotaController(backendClient: backend),
    );
    addTearDown(chat.disposeController);
    addTearDown(machines.dispose);
    addTearDown(agents.dispose);
    addTearDown(settings.dispose);

    await settings.setLanguage(AppLanguage.en);

    await tester.pumpWidget(
      AppScope(
        controller: settings,
        child: MaterialApp(
          home: Scaffold(
            body: HomeNavigationPage(
              agentsController: agents,
              chatController: chat,
              machinesController: machines,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Always-on sessions'), findsOneWidget);
    expect(
      find.text(
        'No always-on sessions. Tap the pin at the top right of a chat to add one.',
      ),
      findsOneWidget,
    );

    backend.unsupported = true;
    await chat.refreshAlwaysOnSessions(machineId: _machine.id);
    await tester.pumpAndSettle();
    expect(find.text('Always-on sessions'), findsNothing);
  });

  testWidgets(
      'tapping a Home always-on session inside BotChatScreen still selects the session after Home unmounts',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _AlwaysOnBackend backend = _AlwaysOnBackend(
      initialAlwaysOn: <AlwaysOnSession>[
        const AlwaysOnSession(
          agentKey: 'codex',
          workdir: '/proj/two',
          sessionId: 'sess-2',
          name: 'Refactor API',
        ),
      ],
    );
    final _SingleMachineController machines = _SingleMachineController();
    final CliAgentsController agents = CliAgentsController();
    final AppSettingsController settings = AppSettingsController();
    final BotChatController chat = BotChatController(
      backendClient: backend,
      quotaController: QuotaController(backendClient: backend),
    );
    addTearDown(chat.disposeController);
    addTearDown(machines.dispose);
    addTearDown(agents.dispose);
    addTearDown(settings.dispose);

    await settings.setLanguage(AppLanguage.en);

    await tester.pumpWidget(
      AppScope(
        controller: settings,
        child: MaterialApp(
          home: BotChatScreen(
            agentsController: agents,
            chatController: chat,
            machinesController: machines,
            settingsController: settings,
            latestVersion: () async => '0.0.0',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(HomeNavigationPage), findsOneWidget);
    await tester.tap(find.text('Refactor API'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeNavigationPage), findsNothing);
    expect(backend.selectedWorkdirs, <String>['/proj/two']);
    expect(agents.activeAgentKey, 'codex');
    expect(chat.agent.key, 'codex');
    expect(chat.activeWorkdir, '/proj/two');
    expect(chat.activeSessionId, 'sess-2');
    expect(backend.selectedSessions, <(String, String)>[('codex', 'sess-2')]);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    await chat.disconnectEvents();
  });
}

class _FixedDeviceIdStore extends DeviceIdStore {
  @override
  Future<String> readOrCreate() async => 'device-test';
}

class _SingleMachineController extends MachineCredentialsController {
  @override
  MachineCredential get activeMachine => _machine;
}

class _AlwaysOnBackend extends BackendClient {
  _AlwaysOnBackend({List<AlwaysOnSession> initialAlwaysOn = const []})
      : _alwaysOn = List<AlwaysOnSession>.of(initialAlwaysOn);

  String _workdir = '/proj/one';
  bool unsupported = false;
  bool failWithLimit = false;
  final List<AlwaysOnSession> _alwaysOn;
  final List<(String, String, bool)> setCalls = <(String, String, bool)>[];
  final List<(String, String, String)> removedCalls =
      <(String, String, String)>[];
  final List<String> selectedWorkdirs = <String>[];
  final List<(String, String)> selectedSessions = <(String, String)>[];

  @override
  Future<bool> health({Duration? timeout}) async => true;

  @override
  Future<List<CliAgent>> fetchAgents({bool verifyCredentials = false}) async =>
      defaultCliAgents;

  @override
  Future<Map<String, bool?>> fetchAuthStatus({
    bool verifyCredentials = false,
  }) async =>
      const <String, bool?>{'claude': true, 'codex': true};

  @override
  Future<WorkdirInfo> workdir() async => WorkdirInfo(dir: _workdir);

  @override
  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) async {
    _workdir = path;
    selectedWorkdirs.add(path);
    return WorkdirInfo(dir: path);
  }

  @override
  Future<List<String>> recentWorkdirs() async => <String>[_workdir];

  @override
  Future<AgentSessionList> fetchSessions(String agentKey) async {
    return AgentSessionList(
      agentKey: agentKey,
      workdir: _workdir,
      activeSessionId: 'default',
      sessions: <AgentSession>[
        AgentSession(
          id: 'default',
          name: 'Main',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        if (agentKey == 'codex' && _workdir == '/proj/two')
          AgentSession(
            id: 'sess-2',
            name: 'Refactor API',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
      ],
    );
  }

  @override
  Future<AgentSessionList> selectSession(
    String agentKey,
    String sessionId,
  ) async {
    selectedSessions.add((agentKey, sessionId));
    return AgentSessionList(
      agentKey: agentKey,
      workdir: _workdir,
      activeSessionId: sessionId,
      sessions: <AgentSession>[
        AgentSession(
          id: 'default',
          name: 'Main',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        AgentSession(
          id: 'sess-2',
          name: 'Refactor API',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ],
    );
  }

  @override
  Future<ChatHistory> fetchHistory(
    String agentKey, {
    required String sessionId,
    int? tail,
  }) async =>
      const ChatHistory(messages: <ChatMessage>[]);

  @override
  Future<List<ChatGroup>> fetchGroups() async => const <ChatGroup>[];

  @override
  Future<UsageReport> usageReport({String? source}) async => UsageReport(
        createdAt: DateTime.utc(2026).toIso8601String(),
        hasStale: false,
        agents: const <UsageAgent>[],
      );

  @override
  Future<AlwaysOnSessionList?> fetchAlwaysOnSessions() async {
    if (unsupported) return null;
    return AlwaysOnSessionList(
      max: 3,
      sessions: List<AlwaysOnSession>.of(_alwaysOn),
    );
  }

  @override
  Future<AlwaysOnSessionList> setSessionAlwaysOn(
    String agentKey,
    String sessionId,
    bool alwaysOn,
  ) async {
    setCalls.add((agentKey, sessionId, alwaysOn));
    if (alwaysOn && failWithLimit) {
      throw BackendException(
        'always-on limit reached (max 3)',
        status: 409,
        code: 'ALWAYS_ON_LIMIT',
      );
    }
    if (alwaysOn) {
      final bool exists = _alwaysOn.any(
        (AlwaysOnSession s) =>
            s.agentKey == agentKey &&
            s.workdir == _workdir &&
            s.sessionId == sessionId,
      );
      if (!exists) {
        _alwaysOn.add(
          AlwaysOnSession(
            agentKey: agentKey,
            workdir: _workdir,
            sessionId: sessionId,
            name: sessionId == 'default' ? 'Main' : sessionId,
          ),
        );
      }
    } else {
      _alwaysOn.removeWhere(
        (AlwaysOnSession s) =>
            s.agentKey == agentKey &&
            s.workdir == _workdir &&
            s.sessionId == sessionId,
      );
    }
    return AlwaysOnSessionList(
      max: 3,
      sessions: List<AlwaysOnSession>.of(_alwaysOn),
    );
  }

  @override
  Future<AlwaysOnSessionList> removeAlwaysOnSession(
    String agentKey,
    String workdir,
    String sessionId,
  ) async {
    removedCalls.add((agentKey, workdir, sessionId));
    _alwaysOn.removeWhere(
      (AlwaysOnSession s) =>
          s.agentKey == agentKey &&
          s.workdir == workdir &&
          s.sessionId == sessionId,
    );
    return AlwaysOnSessionList(
      max: 3,
      sessions: List<AlwaysOnSession>.of(_alwaysOn),
    );
  }

  final List<StreamController<BackendEvent>> _eventStreams =
      <StreamController<BackendEvent>>[];

  @override
  Stream<BackendEvent> streamEvents() {
    late final StreamController<BackendEvent> controller;
    controller = StreamController<BackendEvent>(
      onCancel: () async {
        _eventStreams.remove(controller);
        if (!controller.isClosed) unawaited(controller.close());
      },
    );
    _eventStreams.add(controller);
    return controller.stream;
  }

  @override
  Future<void> close() async {
    for (final StreamController<BackendEvent> controller
        in _eventStreams.toList()) {
      if (!controller.isClosed) unawaited(controller.close());
    }
    _eventStreams.clear();
  }
}
