import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/backend_client.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/features/quota/quota_controller.dart';
import 'package:relay/features/quota/quota_strip.dart';
import 'package:relay/features/quota/quota_usage_screen.dart';
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
          home: QuotaUsageScreen(quotaController: quotaController),
        ),
      ),
    );

    // Both sources are queried separately, and the cards are up before either
    // answers instead of a full-screen spinner.
    expect(
      backendClient.pending.keys,
      unorderedEquals(<String>['claude', 'codex']),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Loading quota...'), findsNWidgets(2));

    backendClient.answer('claude');
    await tester.pump();
    expect(find.text('58% remaining'), findsOneWidget);
    expect(find.text('Loading quota...'), findsOneWidget);

    backendClient.answer('codex');
    await tester.pump();
    expect(find.text('58% remaining'), findsNWidgets(2));
    expect(find.text('Loading quota...'), findsNothing);
    expect(
      quotaController.lastUsageReport?.agents.map((UsageAgent a) => a.key),
      <String>['claude', 'codex'],
    );
  });

  testWidgets('the composer strip holds its place with a spinner and is not a link', (
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
    // Opening usage shows the strip's cached report before either refresh lands.
    expect(find.text('58% remaining'), findsOneWidget);
    expect(find.text('Loading quota...'), findsOneWidget);
    // The usage screen always refreshes both sources; only the strip throttles.
    expect(backendClient.requests, <String?>['claude', 'claude', 'codex']);

    backendClient.answer('codex');
    await tester.pump();
    expect(find.text('58% remaining'), findsNWidgets(2));
    expect(
      quotaController.lastUsageReport?.agents.map((UsageAgent a) => a.key),
      <String>['claude', 'codex'],
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
    expect(backendClient.requests, <String?>['claude', 'claude', 'codex']);
  });
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

  void answer(String source) {
    pending[source]!.complete(
      UsageReport.fromJson(<String, Object?>{
        'agents': <Object?>[
          <String, Object?>{
            'key': source,
            'label': _labels[source],
            'available': true,
            'quotas': <Object?>[
              <String, Object?>{'key': 'five_hour', 'remainingPercent': 58},
            ],
          },
        ],
      }),
    );
  }

  static const Map<String, String> _labels = <String, String>{
    'claude': 'Claude Code',
    'codex': 'Codex',
  };

  @override
  Future<void> close() async {}
}
