import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/backend/backend_client.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/models/cli_agent.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/features/quota/quota_controller.dart';
import 'package:relay_core/features/quota/quota_strip.dart';
import 'package:relay_core/features/quota/quota_usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shows each quota source as soon as it answers', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _UsageBackendClient backendClient = _UsageBackendClient();
    final QuotaController quotaController = QuotaController(
      backendClient: backendClient,
    );
    addTearDown(quotaController.dispose);
    addTearDown(backendClient.close);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: QuotaUsageScreen(
            quotaController: quotaController,
            ensureActiveSessionId: (_) async => 'default',
          ),
        ),
      ),
    );

    // Every source is queried separately, and the cards are up before any
    // answers instead of a full-screen spinner.
    expect(
      backendClient.pending.keys,
      unorderedEquals(<String>['claude', 'codex', 'cursor', 'agy']),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Cursor'), findsOneWidget);
    expect(find.text('Antigravity'), findsOneWidget);
    expect(find.text('Loading quota...'), findsNWidgets(4));

    backendClient.answer('claude');
    await tester.pump();
    expect(find.text('58% remaining'), findsOneWidget);
    expect(find.text('Loading quota...'), findsNWidgets(3));

    backendClient.answer('codex');
    backendClient.answer('cursor');
    backendClient.answer('agy');
    await tester.pump();
    expect(find.text('58% remaining'), findsNWidgets(4));
    expect(find.text('Loading quota...'), findsNothing);
    // Antigravity reads like Claude and Codex: model group plus window.
    expect(find.text('Gemini 5 hours'), findsOneWidget);
    expect(find.text('Gemini This week'), findsOneWidget);
    expect(
      quotaController.lastUsageReport?.agents.map((UsageAgent a) => a.key),
      <String>['claude', 'codex', 'cursor', 'agy'],
    );
  });

  testWidgets(
      'the composer strip holds its place with a spinner and is not a link', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _UsageBackendClient backendClient = _UsageBackendClient();
    final QuotaController quotaController = QuotaController(
      backendClient: backendClient,
    );
    addTearDown(quotaController.dispose);
    addTearDown(backendClient.close);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: Scaffold(
            body: QuotaStrip(
              quotaController: quotaController,
              agentKey: 'claude',
              busy: false,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    backendClient.answer('claude');
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('58%'), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets(
      'strip and usage screen share cached quota and keep their refresh rules',
      (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _CountingUsageBackendClient backendClient =
        _CountingUsageBackendClient();
    final QuotaController quotaController = QuotaController(
      backendClient: backendClient,
    );
    addTearDown(quotaController.dispose);
    addTearDown(backendClient.close);
    bool busy = false;
    late StateSetter rebuild;

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              rebuild = setState;
              return Scaffold(
                appBar: AppBar(
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => QuotaUsageScreen(
                            quotaController: quotaController,
                            ensureActiveSessionId: (_) async => 'default',
                          ),
                        ),
                      ),
                      child: const Text('Usage'),
                    ),
                  ],
                ),
                body: QuotaStrip(
                  quotaController: quotaController,
                  agentKey: 'claude',
                  busy: busy,
                ),
              );
            },
          ),
        ),
      ),
    );
    expect(backendClient.requests, <String?>['claude']);
    backendClient.answer('claude');
    await tester.pump();
    expect(find.text('58%'), findsOneWidget);
    backendClient.pending.clear();

    // A turn ending inside the strip's one-minute window makes no new request.
    rebuild(() => busy = true);
    await tester.pump();
    rebuild(() => busy = false);
    await tester.pump();
    expect(backendClient.requests, <String?>['claude']);

    await tester.tap(find.text('Usage'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // Opening usage shows the strip's cached report before any refresh lands.
    expect(find.text('58% remaining'), findsOneWidget);
    expect(find.text('Loading quota...'), findsNWidgets(3));
    // The usage screen always refreshes every source; only the strip throttles.
    expect(
      backendClient.requests,
      <String?>['claude', 'claude', 'codex', 'cursor', 'agy'],
    );

    backendClient.answer('codex');
    backendClient.answer('cursor');
    backendClient.answer('agy');
    await tester.pump();
    expect(find.text('58% remaining'), findsNWidgets(4));
    expect(
      quotaController.lastUsageReport?.agents.map((UsageAgent a) => a.key),
      <String>['claude', 'codex', 'cursor', 'agy'],
    );
    backendClient.pending['claude']!.complete(
      UsageReport.fromJson(<String, Object?>{
        'agents': <Object?>[
          <String, Object?>{
            'key': 'claude',
            'label': 'Claude Code',
            'available': true,
            'quotas': <Object?>[
              <String, Object?>{'key': 'five_hour', 'remainingPercent': 42},
            ],
          },
        ],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('42% remaining'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    rebuild(() => busy = true);
    await tester.pump();
    expect(find.text('42%'), findsOneWidget);
    expect(
      backendClient.requests,
      <String?>['claude', 'claude', 'codex', 'cursor', 'agy'],
    );
  });

  testWidgets(
      'Antigravity composer strip shows only the Quota usage prompt and skips fetching',
      (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _CountingUsageBackendClient backendClient =
        _CountingUsageBackendClient();
    final QuotaController quotaController = QuotaController(
      backendClient: backendClient,
    );
    final AppSettingsController settings = AppSettingsController();
    addTearDown(quotaController.dispose);
    addTearDown(backendClient.close);
    addTearDown(settings.dispose);
    String agentKey = 'agy';
    bool busy = false;
    late StateSetter rebuild;

    await tester.pumpWidget(
      AppScope(
        controller: settings,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                rebuild = setState;
                return QuotaStrip(
                  quotaController: quotaController,
                  agentKey: agentKey,
                  busy: busy,
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(backendClient.requests, isEmpty);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    expect(find.text('Open Quota usage to view quota'), findsOneWidget);

    await settings.setLanguage(AppLanguage.zh);
    await tester.pump();
    expect(find.text('请在「额度查询」中查看额度'), findsOneWidget);

    // Finishing an Antigravity turn does not query agy quota from the strip.
    rebuild(() => busy = true);
    await tester.pump();
    rebuild(() => busy = false);
    await tester.pump();
    expect(backendClient.requests, isEmpty);

    // Other agents still fetch and render their quota bars normally.
    rebuild(() => agentKey = 'claude');
    await tester.pump();
    expect(backendClient.requests, <String?>['claude']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    backendClient.answer('claude');
    await tester.pump();
    expect(find.text('58%'), findsOneWidget);
  });

  testWidgets(
      'Claude and Codex schedule buttons create, validate, show saving state, '
      'and display scheduled hint line', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _ScheduleUsageBackendClient backendClient =
        _ScheduleUsageBackendClient();
    final QuotaController quotaController = QuotaController(
      backendClient: backendClient,
    );
    final AppSettingsController settings = AppSettingsController();
    addTearDown(quotaController.dispose);
    addTearDown(backendClient.close);
    addTearDown(settings.dispose);

    final List<String> ensuredAgents = <String>[];

    await tester.pumpWidget(
      AppScope(
        controller: settings,
        child: MaterialApp(
          home: QuotaUsageScreen(
            quotaController: quotaController,
            ensureActiveSessionId: (CliAgent agent) async {
              ensuredAgents.add(agent.key);
              return 'session-42';
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Only Claude Code and Codex expose schedule buttons.
    expect(find.text('Scheduled messages'), findsNWidgets(2));
    expect(find.byIcon(Icons.schedule_send_outlined), findsNWidgets(2));
    expect(find.byIcon(Icons.schedule_send_rounded), findsNothing);

    // Tap the Claude Code schedule button to open the dialog.
    await tester.tap(find.text('Scheduled messages').first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Scheduled messages'),
      ),
      findsOneWidget,
    );
    expect(find.text('Clear scheduled'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Refresh:'),
      ),
      findsOneWidget,
    );

    // Empty prompt shows the validation snackbar and does not call the API.
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(find.text('Enter a message.'), findsOneWidget);
    expect(backendClient.createdCalls, 0);

    // Enter a message and tap Send; hold the request in flight to verify the
    // saving/disabled state.
    final Completer<QuotaSchedule> pendingCreate = Completer<QuotaSchedule>();
    backendClient.nextCreate = pendingCreate.future;
    await tester.enterText(find.byType(TextFormField), 'Resume task');
    await tester.tap(find.text('Send'));
    await tester.pump();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed,
      isNull,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    pendingCreate.complete(
      QuotaSchedule(
        id: 'sched-1',
        sourceKey: 'claude',
        agentKey: 'claude',
        sessionId: 'session-42',
        workdir: '/repo',
        prompt: 'Resume task',
        targetResetsAt: '2026-07-13T12:00:00.000Z',
        status: 'pending',
        createdAt: '2026-07-13T10:00:00.000Z',
        updatedAt: '2026-07-13T10:00:00.000Z',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(ensuredAgents, <String>['claude']);
    expect(backendClient.lastCreateArgs, <String, Object?>{
      'sourceKey': 'claude',
      'agentKey': 'claude',
      'sessionId': 'session-42',
      'prompt': 'Resume task',
      'targetResetsAt': '2026-07-13T12:00:00.000Z',
      'replaceExisting': true,
    });
    expect(
      find.text('Updated scheduled message for Claude Code.'),
      findsOneWidget,
    );

    // Panel icon becomes filled/primary and hint line + prompt preview appear.
    expect(find.byIcon(Icons.schedule_send_rounded), findsOneWidget);
    expect(find.byIcon(Icons.schedule_send_outlined), findsOneWidget);
    expect(
      find.textContaining('Scheduled message · sends at'),
      findsOneWidget,
    );
    expect(find.text('Resume task'), findsOneWidget);

    // Switching to Chinese updates the scheduled hint string.
    await settings.setLanguage(AppLanguage.zh);
    await tester.pump();
    expect(find.textContaining('定时消息 · '), findsOneWidget);
    await settings.setLanguage(AppLanguage.en);
    await tester.pump();

    // Tapping the hint line reopens the prefilled dialog with Clear scheduled.
    await tester.tap(find.text('Resume task'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Resume task'), findsOneWidget);
    expect(find.text('Clear scheduled'), findsOneWidget);

    await tester.tap(find.text('Clear scheduled'));
    await tester.pumpAndSettle();

    expect(backendClient.cancelledIds, <String>['sched-1']);
    expect(
      find.text('Cleared scheduled message for Claude Code.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.schedule_send_rounded), findsNothing);
    expect(find.text('Resume task'), findsNothing);
  });

  testWidgets(
      'schedule failures show error snackbar and revision changes reload '
      'schedules only', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final _ScheduleUsageBackendClient backendClient =
        _ScheduleUsageBackendClient();
    final QuotaController quotaController = QuotaController(
      backendClient: backendClient,
    );
    addTearDown(quotaController.dispose);
    addTearDown(backendClient.close);

    await tester.pumpWidget(
      AppScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          home: QuotaUsageScreen(
            quotaController: quotaController,
            ensureActiveSessionId: (_) async => 'default',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final int usageCallsBefore = backendClient.usageCalls;
    final int scheduleCallsBefore = backendClient.scheduleFetches;

    // External schedule update reloads schedules without re-querying usage.
    backendClient.schedules.add(
      const QuotaSchedule(
        id: 'sched-2',
        sourceKey: 'codex',
        agentKey: 'codex',
        sessionId: 'default',
        workdir: '/repo',
        prompt: 'Synced prompt',
        targetResetsAt: '2026-07-13T14:00:00.000Z',
        status: 'pending',
        createdAt: '2026-07-13T10:00:00.000Z',
        updatedAt: '2026-07-13T10:00:00.000Z',
      ),
    );
    quotaController.quotaSchedulesChanged();
    await tester.pumpAndSettle();

    expect(backendClient.usageCalls, usageCallsBefore);
    expect(backendClient.scheduleFetches, scheduleCallsBefore + 1);
    expect(find.text('Synced prompt'), findsOneWidget);

    // Failed save shows scheduleFailed snackbar and re-enables dialog actions.
    backendClient.nextCreateError = BackendException('server down');
    await tester.tap(find.text('Scheduled messages').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Will fail');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Scheduled message failed:'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });
}

class _ScheduleUsageBackendClient extends BackendClient {
  final List<QuotaSchedule> schedules = <QuotaSchedule>[];
  final List<String> cancelledIds = <String>[];
  int createdCalls = 0;
  int usageCalls = 0;
  int scheduleFetches = 0;
  Map<String, Object?>? lastCreateArgs;
  Future<QuotaSchedule>? nextCreate;
  Object? nextCreateError;

  @override
  Future<UsageReport> usageReport({String? source}) async {
    usageCalls += 1;
    return UsageReport.fromJson(<String, Object?>{
      'agents': <Object?>[
        <String, Object?>{
          'key': source,
          'label': _UsageBackendClient._labels[source],
          'available': true,
          'quotas': <Object?>[
            <String, Object?>{
              'key': 'five_hour',
              'remainingPercent': 58,
              'resetsAt': '2026-07-13T12:00:00.000Z',
            },
          ],
        },
      ],
    });
  }

  @override
  Future<List<QuotaSchedule>> quotaSchedules() async {
    scheduleFetches += 1;
    return List<QuotaSchedule>.unmodifiable(schedules);
  }

  @override
  Future<QuotaSchedule> createQuotaSchedule({
    required String sourceKey,
    required String agentKey,
    required String sessionId,
    required String prompt,
    String? targetResetsAt,
    bool replaceExisting = false,
  }) async {
    createdCalls += 1;
    lastCreateArgs = <String, Object?>{
      'sourceKey': sourceKey,
      'agentKey': agentKey,
      'sessionId': sessionId,
      'prompt': prompt,
      'targetResetsAt': targetResetsAt,
      'replaceExisting': replaceExisting,
    };
    if (nextCreateError != null) {
      final Object error = nextCreateError!;
      nextCreateError = null;
      throw error;
    }
    final QuotaSchedule created = await (nextCreate ??
        Future<QuotaSchedule>.value(
          QuotaSchedule(
            id: 'sched-$createdCalls',
            sourceKey: sourceKey,
            agentKey: agentKey,
            sessionId: sessionId,
            workdir: '/repo',
            prompt: prompt,
            targetResetsAt: targetResetsAt,
            status: 'pending',
            createdAt: '2026-07-13T10:00:00.000Z',
            updatedAt: '2026-07-13T10:00:00.000Z',
          ),
        ));
    schedules.removeWhere((QuotaSchedule s) => s.sourceKey == sourceKey);
    schedules.add(created);
    return created;
  }

  @override
  Future<void> cancelQuotaSchedule(String id) async {
    cancelledIds.add(id);
    schedules.removeWhere((QuotaSchedule s) => s.id == id);
  }

  @override
  Future<void> close() async {}
}

class _CountingUsageBackendClient extends _UsageBackendClient {
  final List<String?> requests = <String?>[];

  @override
  Future<UsageReport> usageReport({String? source}) {
    requests.add(source);
    return super.usageReport(source: source);
  }
}

class _UsageBackendClient extends BackendClient {
  final Map<String, Completer<UsageReport>> pending =
      <String, Completer<UsageReport>>{};

  @override
  Future<UsageReport> usageReport({String? source}) {
    return pending.putIfAbsent(source!, Completer<UsageReport>.new).future;
  }

  @override
  Future<List<QuotaSchedule>> quotaSchedules() async => const <QuotaSchedule>[];

  void answer(String source) {
    pending[source]!.complete(
      UsageReport.fromJson(<String, Object?>{
        'agents': <Object?>[
          <String, Object?>{
            'key': source,
            'label': _labels[source],
            'available': true,
            'quotas': source == 'agy'
                ? <Object?>[
                    <String, Object?>{
                      'key': 'gemini-5h',
                      'label': 'Gemini',
                      'window': '5h',
                      'remainingPercent': 58,
                    },
                    <String, Object?>{
                      'key': 'gemini-weekly',
                      'label': 'Gemini',
                      'window': 'weekly',
                      'remainingPercent': 40,
                    },
                  ]
                : <Object?>[
                    <String, Object?>{
                      'key': 'five_hour',
                      'remainingPercent': 58,
                    },
                  ],
          },
        ],
      }),
    );
  }

  static const Map<String, String> _labels = <String, String>{
    'claude': 'Claude Code',
    'codex': 'Codex',
    'cursor': 'Cursor',
    'agy': 'Antigravity',
  };

  @override
  Future<void> close() async {}
}
