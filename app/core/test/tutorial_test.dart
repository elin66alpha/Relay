import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/features/settings/tutorial_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

TutorialArticle _article(
  String slug,
  String title,
  String body, {
  int order = 1,
  String keywords = '',
}) =>
    TutorialArticle(
      slug: slug,
      title: title,
      category: 'C',
      order: order,
      summary: 's',
      keywords: keywords,
      body: body,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every article parses, and both languages hold the same articles',
      () async {
    final List<TutorialArticle> en =
        await loadTutorial('en', bundle: rootBundle);
    final List<TutorialArticle> zh =
        await loadTutorial('zh', bundle: rootBundle);
    expect(en, isNotEmpty);
    String shape(List<TutorialArticle> articles) =>
        articles.map((TutorialArticle a) => '${a.order}:${a.slug}').join(',');
    // Same slugs in the same order, so a link means the same in both.
    expect(shape(zh), shape(en));
    for (final List<TutorialArticle> articles in <List<TutorialArticle>>[
      en,
      zh,
    ]) {
      final Set<String> slugs =
          articles.map((TutorialArticle a) => a.slug).toSet();
      expect(
        articles.map((TutorialArticle a) => a.order).toSet().length,
        articles.length,
        reason: 'orders are unique',
      );
      for (final TutorialArticle article in articles) {
        for (final RegExpMatch link
            in RegExp(r'\]\(([^)\s:]+)\.md\)').allMatches(article.body)) {
          expect(
            slugs,
            contains(link.group(1)),
            reason: '${article.slug} links to ${link.group(1)}',
          );
        }
      }
    }
    // The credential screen opens this article directly.
    expect(en.map((TutorialArticle a) => a.slug), contains('deploy-backend'));
  });

  test('front matter without a required field is rejected', () {
    expect(
      () => parseTutorialArticle('x', '---\ntitle: T\n---\nbody'),
      throwsFormatException,
    );
    final TutorialArticle article = parseTutorialArticle(
      'x',
      '---\ntitle: A: B\ncategory: C\norder: 7\nsummary: S\n---\n\nBody\n',
    );
    expect(article.title, 'A: B');
    expect(article.order, 7);
    expect(article.body, 'Body');
  });

  test('search needs every word and ranks title hits first', () {
    final List<TutorialArticle> articles = <TutorialArticle>[
      _article('body', 'Other', 'mentions swarm and stop', order: 1),
      _article('title', 'Swarm basics', 'how to stop', order: 2),
      _article('keyword', 'Groups', 'stop here', order: 3, keywords: 'swarm'),
      _article('miss', 'Swarm only', 'nothing else', order: 4),
    ];
    expect(
      searchTutorial(articles, '  SWARM   stop ')
          .map((TutorialArticle a) => a.slug),
      <String>['title', 'keyword', 'body'],
    );
    expect(searchTutorial(articles, '   '), isEmpty);
    expect(
      tutorialSnippet(articles.first, 'stop'),
      'mentions swarm and stop',
    );
  });

  testWidgets('the tutorial lists articles, searches, and follows links', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final AppSettingsController settings = AppSettingsController();
    addTearDown(settings.dispose);
    await settings.setLanguage(AppLanguage.en);
    final AppStrings strings = AppStrings(AppLanguage.en);
    // Asset reads complete outside the fake clock, so let real async work
    // run before settling.
    Future<void> settle() async {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }

    await tester.runAsync(() => loadTutorial('en'));
    await tester.pumpWidget(
      AppScope(
        controller: settings,
        child: const MaterialApp(home: TutorialScreen()),
      ),
    );
    await settle();
    expect(find.text('Getting started'), findsOneWidget);
    expect(find.text('What Relay is'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'keepalive');
    await settle();
    expect(find.text('Scheduled messages'), findsOneWidget);
    expect(find.text('What Relay is'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzzz-no-such-word');
    await settle();
    expect(find.text(strings.tutorialNoMatches), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await settle();
    await tester.tap(find.text('What Relay is'));
    await settle();
    expect(find.text('Two parts'), findsOneWidget);

    // An internal link opens the linked article.
    final Finder link = find.descendant(
      of: find.byType(MarkdownBody),
      matching: find.text('Deploy the backend', findRichText: true),
    );
    await tester.ensureVisible(link);
    await settle();
    await tester.tap(link);
    await settle();
    expect(find.text('1. Prepare a backend machine'), findsOneWidget);
  });
}
