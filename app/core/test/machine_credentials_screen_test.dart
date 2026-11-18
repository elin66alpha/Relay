import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/models/machine_credential.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/core/storage/machine_credentials_store.dart';
import 'package:relay_core/features/machines/machine_credentials_controller.dart';
import 'package:relay_core/features/machines/machine_credentials_screen.dart';
import 'package:relay_core/features/settings/app_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('initial connection screen language toggle drives the guide', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MachineCredentialsStore.resetCacheForTest();

    final AppSettingsController settingsController = AppSettingsController();
    await settingsController.load();
    final MachineCredentialsController machinesController =
        MachineCredentialsController(store: _EmptyMachineCredentialsStore());
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

    expect(settingsController.language, AppLanguage.en);
    expect(find.text('中/En'), findsOneWidget);
    expect(find.text('Import machine credential'), findsOneWidget);

    await tester.tap(find.text('中/En'));
    await tester.pumpAndSettle();

    expect(settingsController.language, AppLanguage.zh);
    expect(find.text('导入机器凭证'), findsOneWidget);
    expect(find.text('如何部署后端？'), findsOneWidget);

    await tester.tap(find.text('如何部署后端？'));
    await tester.pumpAndSettle();

    // The deploy guide is the tutorial's `deploy-backend` article.
    expect(find.text('部署后端'), findsWidgets);
    expect(find.textContaining('Node.js 22'), findsWidgets);
  });

  testWidgets(
    'settings displays stored credentials at the top and one Add machine button at the bottom of the list',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      MachineCredentialsStore.resetCacheForTest();

      final MachineCredential first = MachineCredential(
        id: 'm1',
        name: 'Workstation',
        baseUrl: 'https://relay-a.example.com',
        token: 'tok-1',
        createdAt: DateTime.utc(2026).toIso8601String(),
      );
      final MachineCredential second = MachineCredential(
        id: 'm2',
        name: 'Lab Server',
        baseUrl: 'https://relay-b.example.com',
        token: 'tok-2',
        createdAt: DateTime.utc(2026, 1, 2).toIso8601String(),
      );
      final AppSettingsController settingsController = AppSettingsController();
      await settingsController.load();
      final MachineCredentialsController machinesController =
          MachineCredentialsController(
        store: _MemoryMachineCredentialsStore(<MachineCredential>[
          first,
          second,
        ]),
      );
      await machinesController.load();

      await tester.pumpWidget(
        AppScope(
          controller: settingsController,
          child: MaterialApp(
            home: AppSettingsScreen(
              settingsController: settingsController,
              machinesSection: MachineCredentialsSection(
                machinesController: machinesController,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Manage credentials'), findsNothing);
      expect(find.text('Workstation'), findsOneWidget);
      expect(find.text('Lab Server'), findsOneWidget);
      expect(find.text('Add machine'), findsOneWidget);
      expect(find.text('Test current machine'), findsOneWidget);
      expect(find.text('Paste credential'), findsNothing);
      expect(find.text('Upload QR image'), findsNothing);

      // Existing credentials and the single bottom Add machine button appear
      // above Appearance, with Add machine below the last machine row.
      expect(
        tester.getTopLeft(find.text('Workstation')).dy,
        lessThan(tester.getTopLeft(find.text('Lab Server')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Lab Server')).dy,
        lessThan(tester.getTopLeft(find.text('Add machine')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Add machine')).dy,
        lessThan(tester.getTopLeft(find.text('Appearance')).dy),
      );

      // Selecting the second machine switches activeMachine.
      await tester.tap(find.text('Lab Server'));
      await tester.pumpAndSettle();
      expect(machinesController.activeMachine?.id, 'm2');

      // Deleting both machines updates the card while keeping Add machine.
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('No machine connected'), findsOneWidget);
      expect(find.text('Add machine'), findsOneWidget);
      final OutlinedButton testButton = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Test current machine'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(testButton.onPressed, isNull);
    },
  );

  testWidgets(
    'Add machine opens desktop import choices and transitions to paste dialog',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      MachineCredentialsStore.resetCacheForTest();

      final AppSettingsController settingsController = AppSettingsController();
      await settingsController.load();
      await settingsController.setLanguage(AppLanguage.zh);
      final MachineCredentialsController machinesController =
          MachineCredentialsController(
        store: _MemoryMachineCredentialsStore(<MachineCredential>[
          MachineCredential(
            id: 'm1',
            name: '主机 A',
            baseUrl: 'https://a.example.com',
            token: 'tok-1',
            createdAt: DateTime.utc(2026).toIso8601String(),
          ),
        ]),
      );
      await machinesController.load();

      await tester.pumpWidget(
        AppScope(
          controller: settingsController,
          child: MaterialApp(
            home: AppSettingsScreen(
              settingsController: settingsController,
              machinesSection: MachineCredentialsSection(
                machinesController: machinesController,
              ),
            ),
          ),
        ),
      );

      expect(find.text('管理凭证'), findsNothing);
      expect(find.text('添加机器'), findsOneWidget);
      expect(find.text('测试当前机器'), findsOneWidget);

      await tester.tap(find.text('添加机器'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('粘贴凭证'), findsOneWidget);
      expect(find.text('上传二维码图片'), findsOneWidget);
      expect(find.text('扫描二维码'), findsNothing);

      await tester.tap(find.text('粘贴凭证'));
      await tester.pumpAndSettle();

      expect(find.text('导入凭证'), findsOneWidget);
      expect(find.text('凭证内容'), findsOneWidget);
      expect(find.text('上传二维码图片'), findsNothing);

      // Verify canceling closes cleanly with no controller disposal error.
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('导入凭证'), findsNothing);
    },
  );

  testWidgets(
    'Add machine includes Scan QR code alongside paste and upload on mobile',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      MachineCredentialsStore.resetCacheForTest();

      final AppSettingsController settingsController = AppSettingsController();
      await settingsController.load();
      final MachineCredentialsController machinesController =
          MachineCredentialsController(
        store: _MemoryMachineCredentialsStore(<MachineCredential>[
          MachineCredential(
            id: 'm1',
            name: 'Phone Backend',
            baseUrl: 'https://a.example.com',
            token: 'tok-1',
            createdAt: DateTime.utc(2026).toIso8601String(),
          ),
        ]),
      );
      await machinesController.load();

      await tester.pumpWidget(
        AppScope(
          controller: settingsController,
          child: MaterialApp(
            home: AppSettingsScreen(
              settingsController: settingsController,
              machinesSection: MachineCredentialsSection(
                machinesController: machinesController,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Add machine'));
      await tester.pumpAndSettle();

      expect(find.text('Scan QR code'), findsOneWidget);
      expect(find.text('Paste credential'), findsOneWidget);
      expect(find.text('Upload QR image'), findsOneWidget);
    },
  );
}

class _MemoryMachineCredentialsStore extends MachineCredentialsStore {
  _MemoryMachineCredentialsStore(List<MachineCredential> initial)
      : _items = List<MachineCredential>.of(initial),
        _activeId = initial.isEmpty ? null : initial.first.id;

  final List<MachineCredential> _items;
  String? _activeId;

  @override
  Future<List<MachineCredential>> readAll() async {
    return List<MachineCredential>.of(_items);
  }

  @override
  Future<String?> readActiveId() async {
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
  }) async {
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

class _EmptyMachineCredentialsStore extends MachineCredentialsStore {
  @override
  Future<List<MachineCredential>> readAll() async {
    return const <MachineCredential>[];
  }

  @override
  Future<String?> readActiveId() async {
    return null;
  }

  @override
  Future<void> setActive(String id) async {}

  @override
  Future<void> upsert(
    MachineCredential credential, {
    bool makeActive = true,
  }) async {}

  @override
  Future<void> delete(String id) async {}
}
