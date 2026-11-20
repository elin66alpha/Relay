import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/models/agent_options.dart';
import 'package:relay_core/core/models/cli_agent.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/features/chat/swarm_form_dialog.dart';

// Studio's address hashes to this peer id (see models_test.dart).
const String _studioPeer = '4e7eeaf61885';

const MachineCredential _studio = MachineCredential(
  id: 'studio',
  name: 'Studio',
  baseUrl: 'http://10.0.0.5:8787',
  token: 'studio-token',
  createdAt: '',
);
const MachineCredential _broken = MachineCredential(
  id: 'broken',
  name: 'Broken',
  baseUrl: 'http://10.0.0.9:8787',
  token: 'broken-token',
  createdAt: '',
);

void main() {
  testWidgets(
      'groups agents by machine, configures each member, and returns remote keys',
      (WidgetTester tester) async {
    SwarmForm? result;
    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                result = await showDialog<SwarmForm>(
                  context: context,
                  builder: (_) => SwarmFormDialog(
                    title: 'New swarm',
                    agents: const <CliAgent>[
                      CliAgent(
                        key: 'claude',
                        label: 'Claude Code',
                        description: '',
                      ),
                    ],
                    backend: _LocalBackend(),
                    localMachineName: 'Desk',
                    machines: const <MachineCredential>[_studio, _broken],
                    machineBackend: (MachineCredential m) => _MachineBackend(m),
                    initialName: '',
                    initialMembers: const <String>[],
                    initialWorkdir: '',
                    initialConfigs: const <String, Map<String, String>>{},
                    initialPeers: const {},
                    nameEditable: true,
                    workTreeEditable: true,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('This machine · Desk'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Unavailable: Connection refused'), findsOneWidget);
    // Only usable agents of another machine are offered.
    final Finder remoteClaude =
        find.byKey(const ValueKey<String>('swarm-member-$_studioPeer:claude'));
    expect(remoteClaude, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('swarm-member-$_studioPeer:codex')),
      findsNothing,
    );

    final Finder localClaude =
        find.byKey(const ValueKey<String>('swarm-member-claude'));
    await tester.tap(localClaude);
    await tester.pumpAndSettle();
    await tester.tap(remoteClaude);
    await tester.pumpAndSettle();

    // A remote member: no model controls, the machine's defaultDir (not its
    // last-used dir), nickname and prompt.
    await tester.tap(remoteClaude);
    await tester.pumpAndSettle();
    expect(find.text('Configure Claude Code (Studio)'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.text('Work directory on that machine'), findsOneWidget);
    expect(find.text('/srv/studio-default'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Nickname (this swarm)'),
      'Remote',
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Remote'), findsOneWidget);

    // A local member keeps model controls and defaults to local defaultDir.
    await tester.tap(localClaude);
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    expect(find.text("Shared by this machine's members"), findsOneWidget);
    expect(find.text('/local/default'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(result!.name, '');
    expect(result!.workdir, '/local/default');
    expect(result!.members, <String>['claude', '$_studioPeer:claude']);
    expect(result!.configs['$_studioPeer:claude'], <String, String>{
      'workdir': '/srv/studio-default',
      'nickname': 'Remote',
    });
    expect(result!.configs['claude'], <String, String>{'model': 'opus'});
  });

  testWidgets('keeps form open and shows error when onSubmit fails',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () {
                showDialog<SwarmForm>(
                  context: context,
                  builder: (_) => SwarmFormDialog(
                    title: 'New swarm',
                    agents: const <CliAgent>[
                      CliAgent(
                        key: 'claude',
                        label: 'Claude Code',
                        description: '',
                      ),
                    ],
                    backend: _LocalBackend(),
                    localMachineName: 'Desk',
                    machines: const <MachineCredential>[],
                    initialName: '',
                    initialMembers: const <String>['claude'],
                    initialWorkdir: '',
                    initialConfigs: const <String, Map<String, String>>{},
                    initialPeers: const {},
                    nameEditable: true,
                    workTreeEditable: true,
                    onSubmit: (_) async =>
                        'workdir is outside the isolated workspace',
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(
      find.text('workdir is outside the isolated workspace'),
      findsOneWidget,
    );
    expect(find.text('New swarm'), findsOneWidget);
  });
}

class _LocalBackend extends BackendClient {
  @override
  Future<WorkdirInfo> workdir() async => const WorkdirInfo(
        dir: '/local/last-used',
        defaultDir: '/local/default',
      );

  @override
  Future<AgentOptionsCatalog> fetchAgentOptions(String agentKey) async {
    return AgentOptionsCatalog.fromJson(<String, Object?>{
      'agent': agentKey,
      'supports': <String, Object?>{'model': true},
      'model': <Object?>[
        <String, Object?>{'id': 'opus', 'label': 'Opus'},
      ],
    });
  }
}

class _MachineBackend extends BackendClient {
  _MachineBackend(this.machine) : super(machine: machine);

  final MachineCredential machine;

  @override
  Future<List<CliAgent>> fetchAgents({bool verifyCredentials = false}) async {
    if (machine.id == 'broken') {
      throw BackendException('Connection refused');
    }
    return const <CliAgent>[
      CliAgent(key: 'claude', label: 'Claude Code', description: ''),
      CliAgent(
        key: 'codex',
        label: 'Codex',
        description: '',
        installed: false,
      ),
    ];
  }

  @override
  Future<WorkdirInfo> workdir() async => const WorkdirInfo(
        dir: '/srv/last-used',
        defaultDir: '/srv/studio-default',
      );
}
