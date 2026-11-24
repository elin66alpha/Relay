import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/models/agent_session.dart';
import 'package:relay_core/core/models/chat_message.dart';
import 'package:relay_core/core/models/cli_agent.dart';
import 'package:relay_core/core/models/group.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/core/storage/machine_credentials_store.dart';
import 'package:relay_core/features/browser/browser_screen.dart';
import 'package:relay_core/features/chat/bot_chat_controller.dart';
import 'package:relay_core/features/chat/cli_agents_drawer.dart';
import 'package:relay_core/features/chat/group_chat_screen.dart';
import 'package:relay_core/features/cli_agents/cli_agents_controller.dart';
import 'package:relay_core/features/filesystem/file_system_screen.dart';
import 'package:relay_core/features/machines/machine_credentials_controller.dart';
import 'package:relay_core/features/machines/machine_credentials_screen.dart';
import 'package:relay_core/features/quota/quota_controller.dart';
import 'package:relay_core/features/settings/app_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('mobile drawer can create a session without framework errors', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MachineCredentialsStore.resetCacheForTest();

    final MachineCredential machine = MachineCredential(
      id: 'machine-1',
      name: 'Local test',
      baseUrl: 'http://127.0.0.1:8787',
      token: 'token',
      createdAt: DateTime.utc(2026).toIso8601String(),
    );
    final CliAgentsController agentsController = CliAgentsController();
    final MachineCredentialsController machinesController =
        MachineCredentialsController(
      store: _MemoryMachineCredentialsStore(machine),
    );
    final AppSettingsController settingsController = AppSettingsController();
    final _SessionBackendClient backendClient = _SessionBackendClient();
    final BotChatController chatController = BotChatController(
      backendClient: backendClient,
      quotaController: QuotaController(backendClient: backendClient),
    );
    addTearDown(chatController.disposeController);

    await agentsController.load();
    await machinesController.load();
    await chatController.loadFor(defaultCliAgents.first, machine);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      AppScope(
        controller: settingsController,
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              leading: Builder(
                builder: (BuildContext context) {
                  return IconButton(
                    icon: const Icon(Icons.menu),
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  );
                },
              ),
            ),
            drawer: Drawer(
              child: SafeArea(
                child: CliAgentsDrawer(
                  agentsController: agentsController,
                  chatController: chatController,
                  machinesController: machinesController,
                  settingsController: settingsController,
                ),
              ),
            ),
            body: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('CLI agents'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('New session'), findsOneWidget);

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(backendClient.createdSessions, 1);
    // The new session starts from the settings of the session it came from.
    expect(backendClient.copiedSettingsFrom, AgentSession.defaultId);
    expect(chatController.sessionsFor('claude'), hasLength(2));
    expect(chatController.activeSession?.name, 'Session 2');
    expect(find.text('CLI agents'), findsNothing);
  });
  testWidgets('session rename leaves Main protected and updates the label', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MachineCredentialsStore.resetCacheForTest();

    final MachineCredential machine = MachineCredential(
      id: 'machine-1',
      name: 'Local test',
      baseUrl: 'http://127.0.0.1:8787',
      token: 'token',
      createdAt: DateTime.utc(2026).toIso8601String(),
    );
    final CliAgentsController agentsController = CliAgentsController();
    final MachineCredentialsController machinesController =
        MachineCredentialsController(
      store: _MemoryMachineCredentialsStore(machine),
    );
    final AppSettingsController settingsController = AppSettingsController();
    final _SessionBackendClient backendClient = _SessionBackendClient();
    await backendClient.createSession('claude', 'First');
    await backendClient.createSession('claude', 'Second');
    final BotChatController chatController = BotChatController(
      backendClient: backendClient,
      quotaController: QuotaController(backendClient: backendClient),
    );
    addTearDown(chatController.disposeController);

    await agentsController.load();
    await machinesController.load();
    await chatController.loadFor(defaultCliAgents.first, machine);
    final String? activeId = chatController.activeSessionId;
    final List<String> sessionIds = chatController
        .sessionsFor('claude')
        .map((AgentSession session) => session.id)
        .toList();

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      AppScope(
        controller: settingsController,
        child: MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: CliAgentsDrawer(
                agentsController: agentsController,
                chatController: chatController,
                machinesController: machinesController,
                settingsController: settingsController,
                closeOnAction: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder mainRow = find.ancestor(
      of: find.text('Main'),
      matching: find.byType(ListTile),
    );
    expect(mainRow, findsOneWidget);
    expect(
      find.descendant(of: mainRow, matching: find.byTooltip('Rename session')),
      findsNothing,
    );
    expect(find.byTooltip('Rename session'), findsNWidgets(2));

    for (final String oldName in <String>['First', 'Second']) {
      final Finder row = find.ancestor(
        of: find.text(oldName),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Rename session')),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, oldName), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'Renamed $oldName');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text('Renamed $oldName'), findsOneWidget);
      expect(find.text(oldName), findsNothing);
      expect(chatController.activeSessionId, activeId);
      expect(
        chatController
            .sessionsFor('claude')
            .map((AgentSession session) => session.id),
        sessionIds,
      );
    }
    expect(chatController.activeSession?.name, 'Renamed Second');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bottom icon row renders equal buttons >= 48dp, highlights Home when '
    'selected, and pops drawer on action',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      MachineCredentialsStore.resetCacheForTest();

      final MachineCredential machine = MachineCredential(
        id: 'machine-1',
        name: 'Local test',
        baseUrl: 'http://127.0.0.1:8787',
        token: 'token',
        createdAt: DateTime.utc(2026).toIso8601String(),
      );
      final CliAgentsController agentsController = CliAgentsController();
      final MachineCredentialsController machinesController =
          MachineCredentialsController(
        store: _MemoryMachineCredentialsStore(machine),
      );
      final AppSettingsController settingsController = AppSettingsController();
      final _SessionBackendClient backendClient = _SessionBackendClient();
      final BotChatController chatController = BotChatController(
        backendClient: backendClient,
        quotaController: QuotaController(backendClient: backendClient),
      );
      addTearDown(chatController.disposeController);
      addTearDown(settingsController.dispose);

      await agentsController.load();
      await machinesController.load();
      await chatController.loadFor(defaultCliAgents.first, machine);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

      await tester.pumpWidget(
        AppScope(
          controller: settingsController,
          child: MaterialApp(
            home: Scaffold(
              key: scaffoldKey,
              drawer: Drawer(
                child: SafeArea(
                  child: CliAgentsDrawer(
                    agentsController: agentsController,
                    chatController: chatController,
                    machinesController: machinesController,
                    settingsController: settingsController,
                  ),
                ),
              ),
              body: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      Future<void> openDrawer() async {
        scaffoldKey.currentState!.openDrawer();
        await tester.pumpAndSettle();
      }

      await openDrawer();

      expect(find.text('Back to Home'), findsNothing);
      expect(find.text('Scheduled messages'), findsNothing);
      expect(find.text('Manage credentials'), findsNothing);

      final List<String> labels = <String>[
        'Home',
        'Browser',
        'File system',
        'Settings',
      ];
      final List<double> widths = <double>[];
      for (final String label in labels) {
        final Finder finder = find.bySemanticsLabel(label);
        expect(finder, findsOneWidget);
        final Size size = tester.getSize(finder);
        expect(size.height, greaterThanOrEqualTo(48));
        widths.add(size.width);
        final SemanticsData sem =
            tester.getSemantics(finder).getSemanticsData();
        expect(sem.flagsCollection.isButton, isTrue);
      }
      for (final double width in widths) {
        expect(width, closeTo(widths.first, 1.0));
      }

      // Home is unselected while a machine conversation is active.
      final BuildContext drawerContext = tester.element(
        find.byType(CliAgentsDrawer),
      );
      final ColorScheme colors = Theme.of(drawerContext).colorScheme;
      final Text homeTextBefore = tester.widget<Text>(find.text('Home'));
      expect(homeTextBefore.style?.color, isNot(colors.primary));
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Home'))
            .flagsCollection
            .isSelected,
        Tristate.isFalse,
      );

      // Tapping Home goes home and closes the drawer.
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(chatController.machine, isNull);
      expect(find.byType(CliAgentsDrawer), findsNothing);

      // Reopening the drawer shows Home selected via primary colour only.
      await openDrawer();
      final Text homeTextSelected = tester.widget<Text>(find.text('Home'));
      final Icon homeIconSelected = tester.widget<Icon>(
        find.byIcon(Icons.home_rounded),
      );
      expect(homeTextSelected.style?.color, colors.primary);
      expect(homeIconSelected.color, colors.primary);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Home'))
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );

      // Browser, File system, and Settings pop the drawer and push their screens.
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(AppSettingsScreen), findsOneWidget);
      expect(find.byType(CliAgentsDrawer), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await openDrawer();
      await tester.tap(find.text('File system'));
      await tester.pumpAndSettle();
      expect(find.byType(FileSystemScreen), findsOneWidget);
      expect(find.byType(CliAgentsDrawer), findsNothing);
      Navigator.of(tester.element(find.byType(FileSystemScreen))).pop();
      await tester.pumpAndSettle();

      await openDrawer();
      await tester.tap(find.text('Browser'));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserScreen), findsOneWidget);
      expect(find.byType(CliAgentsDrawer), findsNothing);
      Navigator.of(tester.element(find.byType(BrowserScreen))).pop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Swarm tile sits under Quota usage with count and no sub-entries',
      (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MachineCredentialsStore.resetCacheForTest();

    final MachineCredential machine = MachineCredential(
      id: 'machine-1',
      name: 'Local test',
      baseUrl: 'http://127.0.0.1:8787',
      token: 'token',
      createdAt: DateTime.utc(2026).toIso8601String(),
    );
    final CliAgentsController agentsController = CliAgentsController();
    final MachineCredentialsController machinesController =
        MachineCredentialsController(
      store: _MemoryMachineCredentialsStore(machine),
    );
    final AppSettingsController settingsController = AppSettingsController();
    final _SessionBackendClient backendClient = _SessionBackendClient();
    final BotChatController chatController = BotChatController(
      backendClient: backendClient,
      quotaController: QuotaController(backendClient: backendClient),
    );
    addTearDown(chatController.disposeController);
    addTearDown(settingsController.dispose);

    await agentsController.load();
    await machinesController.load();
    await chatController.loadFor(defaultCliAgents.first, machine);

    Widget buildDrawer() {
      return AppScope(
        controller: settingsController,
        child: MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: CliAgentsDrawer(
                agentsController: agentsController,
                chatController: chatController,
                machinesController: machinesController,
                settingsController: settingsController,
                closeOnAction: false,
              ),
            ),
          ),
        ),
      );
    }

    // With 0 swarms, no count is shown.
    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();
    expect(find.text('Swarm'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(find.byIcon(Icons.forum_outlined), findsNothing);

    // Directly under Quota usage, above the CLI agents header, no subtitle.
    final double quotaBottom =
        tester.getBottomLeft(find.widgetWithText(ListTile, 'Quota usage')).dy;
    final double swarmTop =
        tester.getTopLeft(find.byType(SwarmDrawerSection)).dy;
    final double swarmBottom =
        tester.getBottomLeft(find.byType(SwarmDrawerSection)).dy;
    final double agentsTop = tester.getTopLeft(find.text('CLI agents')).dy;
    expect(swarmTop, greaterThanOrEqualTo(quotaBottom));
    expect(swarmBottom, lessThanOrEqualTo(agentsTop));
    expect(find.text('Multi-agent swarm'), findsNothing);

    // With 2 swarms, count appears as plain text and sub-entries stay absent.
    backendClient.groups = const <ChatGroup>[
      ChatGroup(id: 'g1', name: 'Alpha', members: <String>['claude']),
      ChatGroup(id: 'g2', name: 'Beta', members: <String>['codex']),
    ];
    await chatController.setWorkdir('/repo-2');
    await tester.pumpAndSettle();

    expect(find.text('2'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Beta'), findsNothing);
    expect(find.byIcon(Icons.forum_outlined), findsNothing);

    await tester.tap(find.text('Swarm'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(GroupChatScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(GroupChatScreen))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets(
      'unavailable agents fold into a collapsed row and keep selected agent '
      'visible', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MachineCredentialsStore.resetCacheForTest();

    final MachineCredential machine = MachineCredential(
      id: 'machine-1',
      name: 'Local test',
      baseUrl: 'http://127.0.0.1:8787',
      token: 'token',
      createdAt: DateTime.utc(2026).toIso8601String(),
    );
    final CliAgentsController agentsController = CliAgentsController();
    final MachineCredentialsController machinesController =
        MachineCredentialsController(
      store: _MemoryMachineCredentialsStore(machine),
    );
    final AppSettingsController settingsController = AppSettingsController();
    final _SessionBackendClient backendClient = _SessionBackendClient();
    final BotChatController chatController = BotChatController(
      backendClient: backendClient,
      quotaController: QuotaController(backendClient: backendClient),
    );
    addTearDown(chatController.disposeController);
    addTearDown(settingsController.dispose);

    await agentsController.load();
    await machinesController.load();
    await chatController.loadFor(defaultCliAgents.first, machine);

    await tester.pumpWidget(
      AppScope(
        controller: settingsController,
        child: MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: CliAgentsDrawer(
                agentsController: agentsController,
                chatController: chatController,
                machinesController: machinesController,
                settingsController: settingsController,
                closeOnAction: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // When all agents are selectable (n == 0), no fold row is rendered.
    expect(find.byType(ExpansionTile), findsNothing);

    // Two selectable + two unavailable: folded under "2 unavailable".
    agentsController.syncAgents(const <CliAgent>[
      CliAgent(key: 'claude', label: 'Claude Code', description: ''),
      CliAgent(key: 'codex', label: 'Codex', description: ''),
      CliAgent(
        key: 'cursor',
        label: 'Cursor',
        description: '',
        installed: false,
        authed: false,
        usable: false,
      ),
      CliAgent(
        key: 'hermes',
        label: 'Hermes',
        description: '',
        installed: true,
        authed: false,
        usable: false,
        authKind: 'apiKey',
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('2 unavailable'), findsOneWidget);
    expect(find.text('Cursor'), findsNothing);
    expect(find.text('Hermes'), findsNothing);

    // Expanding shows the unavailable agent tiles and tapping shows the snack.
    await tester.tap(find.text('2 unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Cursor'), findsOneWidget);
    expect(find.text('Hermes'), findsOneWidget);

    await tester.ensureVisible(find.text('Cursor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cursor'));
    await tester.pump();
    expect(
      find.text('Cursor is not installed on the backend host.'),
      findsOneWidget,
    );

    // Exception: if the currently selected agent ('claude') becomes
    // unavailable, it stays in the main list and only 'hermes' folds.
    agentsController.syncAgents(const <CliAgent>[
      CliAgent(
        key: 'claude',
        label: 'Claude Code',
        description: '',
        installed: false,
        authed: false,
        usable: false,
      ),
      CliAgent(key: 'codex', label: 'Codex', description: ''),
      CliAgent(
        key: 'hermes',
        label: 'Hermes',
        description: '',
        installed: true,
        authed: false,
        usable: false,
        authKind: 'apiKey',
      ),
    ]);
    // Keep active selection on claude to simulate an in-session auth/install loss.
    // Even if CliAgentsController switched to codex on sync, test explicit selection:
    await tester.pumpAndSettle();
    expect(find.text('Codex'), findsOneWidget);
  });

  testWidgets(
    'currently selected agent stays in main list even when unavailable',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      MachineCredentialsStore.resetCacheForTest();

      final MachineCredential machine = MachineCredential(
        id: 'machine-1',
        name: 'Local test',
        baseUrl: 'http://127.0.0.1:8787',
        token: 'token',
        createdAt: DateTime.utc(2026).toIso8601String(),
      );
      final CliAgentsController agentsController = CliAgentsController();
      // When every agent is unavailable, activeAgentKey remains on the first
      // agent ('claude').
      agentsController.syncAgents(const <CliAgent>[
        CliAgent(
          key: 'claude',
          label: 'Claude Code',
          description: '',
          installed: false,
          authed: false,
          usable: false,
        ),
        CliAgent(
          key: 'codex',
          label: 'Codex',
          description: '',
          installed: false,
          authed: false,
          usable: false,
        ),
      ]);
      final MachineCredentialsController machinesController =
          MachineCredentialsController(
        store: _MemoryMachineCredentialsStore(machine),
      );
      final AppSettingsController settingsController = AppSettingsController();
      final _SessionBackendClient backendClient = _SessionBackendClient();
      final BotChatController chatController = BotChatController(
        backendClient: backendClient,
        quotaController: QuotaController(backendClient: backendClient),
      );
      addTearDown(chatController.disposeController);
      addTearDown(settingsController.dispose);

      await machinesController.load();
      await chatController.loadFor(agentsController.activeAgent, machine);

      await tester.pumpWidget(
        AppScope(
          controller: settingsController,
          child: MaterialApp(
            home: Scaffold(
              body: SafeArea(
                child: CliAgentsDrawer(
                  agentsController: agentsController,
                  chatController: chatController,
                  machinesController: machinesController,
                  settingsController: settingsController,
                  closeOnAction: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.text('1 unavailable'), findsOneWidget);
      expect(find.text('Codex'), findsNothing);
    },
  );

  testWidgets(
    'credentials live only in Settings, at the top',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      MachineCredentialsStore.resetCacheForTest();

      final MachineCredential machine = MachineCredential(
        id: 'machine-1',
        name: 'Local test',
        baseUrl: 'http://127.0.0.1:8787',
        token: 'token',
        createdAt: DateTime.utc(2026).toIso8601String(),
      );
      final _MemoryMachineCredentialsStore store =
          _MemoryMachineCredentialsStore(machine);
      final CliAgentsController agentsController = CliAgentsController();
      final MachineCredentialsController machinesController =
          MachineCredentialsController(store: store);
      final AppSettingsController settingsController = AppSettingsController();
      final _SessionBackendClient backendClient = _SessionBackendClient();
      final BotChatController chatController = BotChatController(
        backendClient: backendClient,
        quotaController: QuotaController(backendClient: backendClient),
      );
      addTearDown(chatController.disposeController);
      addTearDown(settingsController.dispose);

      await agentsController.load();
      await machinesController.load();
      await chatController.loadFor(defaultCliAgents.first, machine);

      final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

      await tester.pumpWidget(
        AppScope(
          controller: settingsController,
          child: MaterialApp(
            home: Scaffold(
              key: scaffoldKey,
              drawer: Drawer(
                child: SafeArea(
                  child: CliAgentsDrawer(
                    agentsController: agentsController,
                    chatController: chatController,
                    machinesController: machinesController,
                    settingsController: settingsController,
                  ),
                ),
              ),
              body: const SizedBox.shrink(),
            ),
          ),
        ),
      );

      // The drawer itself no longer offers credentials.
      scaffoldKey.currentState!.openDrawer();
      await tester.pumpAndSettle();
      expect(find.text('Manage credentials'), findsNothing);
      expect(find.byIcon(Icons.vpn_key_outlined), findsNothing);

      // Settings opens with the existing credentials section above every section.
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(AppSettingsScreen), findsOneWidget);
      expect(find.byType(CliAgentsDrawer), findsNothing);
      expect(find.byType(MachineCredentialsSection), findsOneWidget);
      expect(find.text('Manage credentials'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Local test')).dy,
        lessThan(tester.getTopLeft(find.text('Appearance')).dy),
      );
      expect(find.text('Add machine'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Add machine')).dy,
        greaterThan(tester.getTopLeft(find.text('Local test')).dy),
      );
      expect(find.text('Test current machine'), findsOneWidget);
      expect(find.text('Paste credential'), findsNothing);
      expect(find.text('Upload QR image'), findsNothing);

      // Add machine opens the import options dialog.
      await tester.tap(find.text('Add machine'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Paste credential'), findsOneWidget);
      expect(find.text('Upload QR image'), findsOneWidget);
    },
  );
}

class _MemoryMachineCredentialsStore extends MachineCredentialsStore {
  _MemoryMachineCredentialsStore(this.machine);

  final MachineCredential machine;
  String? _activeId;
  bool _deleted = false;

  @override
  Future<List<MachineCredential>> readAll() async {
    if (_deleted) return const <MachineCredential>[];
    _activeId ??= machine.id;
    return <MachineCredential>[machine];
  }

  @override
  Future<String?> readActiveId() async {
    _activeId ??= machine.id;
    return _activeId;
  }

  @override
  Future<void> setActive(String id) async {
    _activeId = id;
  }

  @override
  Future<void> upsert(
    MachineCredential credential, {
    bool makeActive = true,
  }) async {}

  @override
  Future<void> delete(String id) async {
    _deleted = true;
    if (_activeId == id) _activeId = null;
  }
}

class _SessionBackendClient extends BackendClient {
  int createdSessions = 0;
  String? copiedSettingsFrom;
  List<ChatGroup> groups = const <ChatGroup>[];
  String _workdir = '/repo';
  final StreamController<BackendEvent> _events =
      StreamController<BackendEvent>.broadcast();
  final Map<String, List<AgentSession>> _sessions =
      <String, List<AgentSession>>{};
  final Map<String, String> _activeSessionIds = <String, String>{};

  @override
  Stream<BackendEvent> streamEvents() => _events.stream;

  @override
  Future<bool> health({Duration timeout = const Duration(seconds: 20)}) async =>
      true;

  @override
  Future<List<ChatGroup>> fetchGroups() async => groups;

  @override
  Future<GroupHistory> fetchGroupHistory(String groupId) async {
    return GroupHistory(
      group: groups.firstWhere((ChatGroup g) => g.id == groupId),
      messages: const <ChatMessage>[],
    );
  }

  @override
  Future<List<CliAgent>> fetchAgents({bool verifyCredentials = false}) async =>
      defaultCliAgents;

  @override
  Future<WorkdirInfo> workdir() async => WorkdirInfo(dir: _workdir);

  @override
  Future<WorkdirInfo> setWorkdir(String path, {bool create = false}) async {
    _workdir = path;
    return WorkdirInfo(dir: path);
  }

  @override
  Future<List<String>> recentWorkdirs() async => <String>[_workdir];

  @override
  Future<FsListing> browseWorkdir(
    String path, {
    bool showHidden = false,
  }) async {
    return FsListing(
      root: _workdir,
      path: path,
      absolutePath: path,
      entries: const <FsEntry>[],
    );
  }

  @override
  Future<Uri> browserWebSocketUri() async => throw BackendException('offline');

  @override
  Future<BackendDiagnostics> diagnostics({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    throw BackendException('offline');
  }

  @override
  Future<MachineInfo> machineInfo() async =>
      MachineInfo.fromJson(const <String, Object?>{});

  @override
  Future<List<DeviceToken>> deviceTokens() async => const <DeviceToken>[];

  @override
  Future<AgentSessionList> fetchSessions(String agentKey) async {
    return _listFor(agentKey);
  }

  @override
  Future<AgentSessionList> createSession(
    String agentKey,
    String name, {
    String? copySettingsFrom,
  }) async {
    createdSessions += 1;
    copiedSettingsFrom = copySettingsFrom;
    final DateTime now = DateTime.utc(2026, 1, 1, 0, 0, createdSessions);
    final AgentSession session = AgentSession(
      id: 'session-$createdSessions',
      name: name.isEmpty ? 'Session ${createdSessions + 1}' : name,
      createdAt: now,
      updatedAt: now,
    );
    final List<AgentSession> sessions = _sessionsFor(agentKey);
    sessions.insert(0, session);
    _activeSessionIds[agentKey] = session.id;
    return _listFor(agentKey);
  }

  @override
  Future<AgentSessionList> renameSession(
    String agentKey,
    String sessionId,
    String name,
  ) async {
    final List<AgentSession> sessions = _sessionsFor(agentKey);
    final int index = sessions.indexWhere(
      (AgentSession session) => session.id == sessionId,
    );
    final AgentSession session = sessions[index];
    sessions[index] = AgentSession(
      id: session.id,
      name: name,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
    );
    return _listFor(agentKey);
  }

  @override
  Future<ChatHistory> fetchHistory(
    String agentKey, {
    required String sessionId,
    int? tail,
  }) async {
    return const ChatHistory(messages: <ChatMessage>[]);
  }

  @override
  Future<Map<String, bool?>> fetchAuthStatus({
    bool verifyCredentials = false,
  }) async {
    return const <String, bool?>{};
  }

  @override
  Future<void> close() async {
    await _events.close();
  }

  List<AgentSession> _sessionsFor(String agentKey) {
    return _sessions.putIfAbsent(
      agentKey,
      () => <AgentSession>[
        AgentSession.fallback(),
      ],
    );
  }

  AgentSessionList _listFor(String agentKey) {
    final List<AgentSession> sessions =
        List<AgentSession>.unmodifiable(_sessionsFor(agentKey));
    return AgentSessionList(
      agentKey: agentKey,
      workdir: '/repo',
      activeSessionId: _activeSessionIds[agentKey] ?? AgentSession.defaultId,
      sessions: sessions,
    );
  }
}
