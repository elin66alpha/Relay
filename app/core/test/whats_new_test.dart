import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/features/settings/whats_new_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final AppLanguage language in AppLanguage.values) {
    testWidgets('What\'s new lists highlights and other changes ($language)', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final AppSettingsController settings = AppSettingsController();
      addTearDown(settings.dispose);
      await settings.setLanguage(language);
      final AppStrings strings = AppStrings(language);
      await tester.pumpWidget(
        AppScope(
          controller: settings,
          child: const MaterialApp(home: WhatsNewScreen()),
        ),
      );
      expect(find.text(strings.whatsNew), findsOneWidget);
      final RegExp versionPattern = RegExp(r'^\d+\.\d+\.\d+$');
      final Map<String, int> highlights = <String, int>{};
      String? version;
      for (final Widget widget in tester.widgetList(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Card ||
              widget is Text && versionPattern.hasMatch(widget.data ?? ''),
        ),
      )) {
        if (widget is Text) {
          version = widget.data!;
          expect(highlights.containsKey(version), isFalse);
          highlights[version] = 0;
        } else {
          expect(version, isNotNull, reason: 'Highlights follow their release');
          highlights[version!] = highlights[version]! + 1;
        }
      }
      expect(highlights, isNotEmpty);
      for (final int count in highlights.values) {
        expect(count, inInclusiveRange(1, 3));
      }
      final List<String> versions = highlights.keys.toList();
      final List<String> newestFirst = versions.toList()
        ..sort((String a, String b) {
          final List<int> left = a.split('.').map(int.parse).toList();
          final List<int> right = b.split('.').map(int.parse).toList();
          for (int i = 0; i < left.length; i++) {
            final int comparison = right[i].compareTo(left[i]);
            if (comparison != 0) return comparison;
          }
          return 0;
        });
      expect(versions, newestFirst);
      expect(find.text(strings.otherChanges), findsNWidgets(versions.length));
      expect(whatsNewSummary(strings), startsWith('${versions.first} · '));
      expect(tester.takeException(), isNull);
    });
  }
}
