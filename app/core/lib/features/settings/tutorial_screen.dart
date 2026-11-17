import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/widgets/code_block.dart';

/// One tutorial article: a Markdown file under `assets/tutorial/<lang>/`,
/// named `<slug>.md`, that starts with a front matter block:
///
/// ```
/// ---
/// title: Deploy the backend
/// category: Getting started
/// order: 120
/// summary: One line shown in the article list.
/// keywords: install, setup
/// ---
/// ```
///
/// Categories sort by the lowest `order` among their articles.
class TutorialArticle {
  const TutorialArticle({
    required this.slug,
    required this.title,
    required this.category,
    required this.order,
    required this.summary,
    required this.keywords,
    required this.body,
  });

  final String slug;
  final String title;
  final String category;
  final int order;
  final String summary;
  final String keywords;
  final String body;
}

TutorialArticle parseTutorialArticle(String slug, String source) {
  final RegExpMatch? match =
      RegExp(r'^---\r?\n([\s\S]*?)\r?\n---\r?\n').firstMatch(source);
  if (match == null) throw FormatException('$slug: missing front matter');
  final Map<String, String> fields = <String, String>{
    for (final String line in match.group(1)!.split('\n'))
      if (line.contains(':'))
        line.substring(0, line.indexOf(':')).trim():
            line.substring(line.indexOf(':') + 1).trim(),
  };
  String field(String key) {
    final String? value = fields[key];
    if (value == null || value.isEmpty) {
      throw FormatException('$slug: missing $key');
    }
    return value;
  }

  final int? order = int.tryParse(field('order'));
  if (order == null) throw FormatException('$slug: order is not a number');
  return TutorialArticle(
    slug: slug,
    title: field('title'),
    category: field('category'),
    order: order,
    summary: field('summary'),
    keywords: fields['keywords'] ?? '',
    body: source.substring(match.end).trim(),
  );
}

final Map<String, Future<List<TutorialArticle>>> _libraries =
    <String, Future<List<TutorialArticle>>>{};

/// Every article for [language] (`en` or `zh`), sorted by `order`. The list
/// comes from the asset manifest, so adding a Markdown file adds an article.
Future<List<TutorialArticle>> loadTutorial(
  String language, {
  AssetBundle? bundle,
}) {
  Future<List<TutorialArticle>> load() async {
    final AssetBundle assets = bundle ?? rootBundle;
    final AssetManifest manifest =
        await AssetManifest.loadFromAssetBundle(assets);
    final RegExp path = RegExp('assets/tutorial/$language/([^/]+)\\.md\$');
    final List<TutorialArticle> articles = <TutorialArticle>[
      for (final String key in manifest.listAssets())
        if (path.firstMatch(key) case final RegExpMatch hit)
          parseTutorialArticle(hit.group(1)!, await assets.loadString(key)),
    ]..sort((TutorialArticle a, TutorialArticle b) => a.order - b.order);
    return articles;
  }

  if (bundle != null) return load();
  return _libraries.putIfAbsent(language, load);
}

/// Articles containing every word of [query], best first: a word in the
/// title counts most, then summary and keywords, then the body.
List<TutorialArticle> searchTutorial(
  List<TutorialArticle> articles,
  String query,
) {
  final List<String> words = query
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((String w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return const <TutorialArticle>[];
  final List<(TutorialArticle, int)> hits = <(TutorialArticle, int)>[];
  for (final TutorialArticle article in articles) {
    final String title = article.title.toLowerCase();
    final String meta =
        '${article.summary} ${article.keywords} ${article.category}'
            .toLowerCase();
    final String body = article.body.toLowerCase();
    int score = 0;
    for (final String word in words) {
      final int wordScore = title.contains(word)
          ? 4
          : meta.contains(word)
              ? 2
              : body.contains(word)
                  ? 1
                  : 0;
      if (wordScore == 0) {
        score = 0;
        break;
      }
      score += wordScore;
    }
    if (score > 0) hits.add((article, score));
  }
  hits.sort(
    ((TutorialArticle, int) a, (TutorialArticle, int) b) =>
        a.$2 != b.$2 ? b.$2 - a.$2 : a.$1.order - b.$1.order,
  );
  return <TutorialArticle>[for (final (TutorialArticle, int) h in hits) h.$1];
}

/// Plain text around the first body occurrence of [query]'s first word.
String tutorialSnippet(TutorialArticle article, String query) {
  final String text = article.body
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAll(RegExp(r'\[([^\]]*)\]\([^)]*\)'), r'$1')
      .replaceAll(RegExp(r'[#*`>|_]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final String word = query.trim().split(RegExp(r'\s+')).first.toLowerCase();
  final int at = word.isEmpty ? -1 : text.toLowerCase().indexOf(word);
  if (at < 0) return article.summary;
  final int start = (at - 40).clamp(0, text.length);
  final int end = (at + 120).clamp(0, text.length);
  return '${start > 0 ? '…' : ''}${text.substring(start, end)}'
      '${end < text.length ? '…' : ''}';
}

String _language(AppStrings strings) => strings.isZh ? 'zh' : 'en';

class TutorialScreen extends StatefulWidget {
  const TutorialScreen({super.key});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _TutorialScreenState extends State<TutorialScreen> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(TutorialArticle article) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TutorialArticleScreen(slug: article.slug),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.tutorial)),
      body: SafeArea(
        child: FutureBuilder<List<TutorialArticle>>(
          future: loadTutorial(_language(strings)),
          builder: (
            BuildContext context,
            AsyncSnapshot<List<TutorialArticle>> snapshot,
          ) {
            if (snapshot.hasError) {
              return Center(child: Text(strings.tutorialLoadFailed));
            }
            final List<TutorialArticle>? articles = snapshot.data;
            if (articles == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final String query = _query.text.trim();
            final List<Widget> content;
            if (query.isEmpty) {
              final Map<String, List<TutorialArticle>> categories =
                  <String, List<TutorialArticle>>{};
              for (final TutorialArticle article in articles) {
                categories
                    .putIfAbsent(article.category, () => <TutorialArticle>[])
                    .add(article);
              }
              content = <Widget>[
                for (final MapEntry<String, List<TutorialArticle>> category
                    in categories.entries) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                    child: Text(
                      category.key,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Column(
                      children: <Widget>[
                        for (final TutorialArticle article in category.value)
                          ListTile(
                            title: Text(article.title),
                            subtitle: Text(article.summary),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _open(article),
                          ),
                      ],
                    ),
                  ),
                ],
              ];
            } else {
              final List<TutorialArticle> hits =
                  searchTutorial(articles, query);
              content = hits.isEmpty
                  ? <Widget>[
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(child: Text(strings.tutorialNoMatches)),
                      ),
                    ]
                  : <Widget>[
                      const SizedBox(height: 8),
                      Card(
                        margin: EdgeInsets.zero,
                        child: Column(
                          children: <Widget>[
                            for (final TutorialArticle article in hits)
                              ListTile(
                                title: Text(article.title),
                                subtitle: Text(
                                  '${article.category} · '
                                  '${tutorialSnippet(article, query)}',
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => _open(article),
                              ),
                          ],
                        ),
                      ),
                    ];
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: <Widget>[
                Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        TextField(
                          controller: _query,
                          onChanged: (_) => setState(() {}),
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: strings.tutorialSearchHint,
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: strings.clear,
                                    icon: const Icon(Icons.close),
                                    onPressed: () =>
                                        setState(() => _query.clear()),
                                  ),
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        ...content,
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One article, opened from the list, from a link in another article, or
/// directly (the credential screen opens `deploy-backend`).
class TutorialArticleScreen extends StatelessWidget {
  const TutorialArticleScreen({super.key, required this.slug});

  final String slug;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final ThemeData theme = Theme.of(context);
    return FutureBuilder<List<TutorialArticle>>(
      future: loadTutorial(_language(strings)),
      builder: (
        BuildContext context,
        AsyncSnapshot<List<TutorialArticle>> snapshot,
      ) {
        final TutorialArticle? article = snapshot.data
            ?.where((TutorialArticle a) => a.slug == slug)
            .firstOrNull;
        final TextStyle base = (theme.textTheme.bodyMedium ?? const TextStyle())
            .copyWith(color: theme.colorScheme.onSurface, height: 1.55);
        return Scaffold(
          appBar: AppBar(title: Text(article?.title ?? strings.tutorial)),
          body: SafeArea(
            child: article == null
                ? Center(
                    child: snapshot.connectionState == ConnectionState.done
                        ? Text(strings.tutorialLoadFailed)
                        : const CircularProgressIndicator(),
                  )
                : SelectionArea(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                      children: <Widget>[
                        Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 760),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Text(
                                  article.category,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  article.title,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 16),
                                MarkdownBody(
                                  data: article.body,
                                  selectable: false,
                                  softLineBreak: true,
                                  styleSheet: relayMarkdownStyleSheet(
                                    theme.colorScheme.onSurface,
                                    base,
                                  ),
                                  builders: <String, MarkdownElementBuilder>{
                                    'pre': CodeBlockBuilder(
                                      theme.colorScheme.onSurface,
                                    ),
                                  },
                                  onTapLink: (_, String? href, __) =>
                                      _openLink(context, href),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }

  static void _openLink(BuildContext context, String? href) {
    if (href == null) return;
    final Uri? uri = Uri.tryParse(href);
    if (uri == null) return;
    if (uri.hasScheme) {
      if (uri.scheme == 'https') {
        launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }
    // Links between articles are relative `<slug>.md` paths, the same form
    // the repository's link check resolves.
    final String target = uri.path.split('/').last;
    if (!target.endsWith('.md')) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TutorialArticleScreen(
          slug: target.substring(0, target.length - 3),
        ),
      ),
    );
  }
}
