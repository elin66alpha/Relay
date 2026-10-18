import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/i18n/app_strings.dart';
import 'package:relay/core/settings/app_settings_controller.dart';
import 'package:relay/features/settings/whats_new_screen.dart';
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
      expect(find.text('0.1.8'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(3));
      expect(find.text(strings.otherChanges), findsOneWidget);
      expect(whatsNewSummary(strings), startsWith('0.1.8 · '));
      expect(tester.takeException(), isNull);
    });
  }
}
