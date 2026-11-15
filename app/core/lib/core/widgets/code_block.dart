import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';

import '../i18n/app_strings.dart';
import '../theme/app_theme.dart';

// The languages agents actually write, rather than all ~190 grammars, to keep
// the Web bundle small. Each grammar registers its own aliases (js, ts, sh, py,
// yml, html, …); anything else renders as plain monospace.
final Highlight _highlighter = Highlight()
  ..registerLanguages(<String, Mode>{
    'bash': langBash,
    'c': langC,
    'cpp': langCpp,
    'csharp': langCsharp,
    'css': langCss,
    'dart': langDart,
    'diff': langDiff,
    'dockerfile': langDockerfile,
    'go': langGo,
    'ini': langIni,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'kotlin': langKotlin,
    'makefile': langMakefile,
    'markdown': langMarkdown,
    'powershell': langPowershell,
    'python': langPython,
    'ruby': langRuby,
    'rust': langRust,
    'shell': langShell,
    'sql': langSql,
    'swift': langSwift,
    'typescript': langTypescript,
    'xml': langXml,
    'yaml': langYaml,
  });

/// Character cap past which code blocks skip synchronous syntax highlighting
/// and large Markdown previews open in source view so frames do not stall.
const int maxHighlightedChars = 20000;

/// Shared Markdown stylesheet for chat messages and Markdown file previews.
MarkdownStyleSheet relayMarkdownStyleSheet(
  Color color,
  TextStyle base,
) {
  // Tints of the text colour rather than scheme surfaces, so code reads the
  // same on an agent panel, tinted system reply, and file preview in either theme.
  final Color codeBackground = color.withValues(alpha: 0.05);
  final Color borderColor = color.withValues(alpha: 0.14);
  return MarkdownStyleSheet(
    p: base,
    pPadding: EdgeInsets.zero,
    strong: base.copyWith(fontWeight: FontWeight.w700),
    em: base.copyWith(fontStyle: FontStyle.italic),
    h1: base.copyWith(
      fontSize: 21,
      fontWeight: FontWeight.w800,
      height: 1.25,
    ),
    h1Padding: const EdgeInsets.only(top: 4, bottom: 6),
    h2: base.copyWith(
      fontSize: 19,
      fontWeight: FontWeight.w800,
      height: 1.28,
    ),
    h2Padding: const EdgeInsets.only(top: 4, bottom: 5),
    h3: base.copyWith(
      fontSize: 17,
      fontWeight: FontWeight.w700,
      height: 1.30,
    ),
    h3Padding: const EdgeInsets.only(top: 3, bottom: 4),
    h4: base.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
    h4Padding: const EdgeInsets.only(top: 3, bottom: 3),
    h5: base.copyWith(fontWeight: FontWeight.w700),
    h5Padding: const EdgeInsets.only(top: 2, bottom: 2),
    h6: base.copyWith(fontWeight: FontWeight.w700),
    h6Padding: const EdgeInsets.only(top: 2, bottom: 2),
    blockSpacing: 8,
    listIndent: 22,
    listBullet: base,
    code: AppTheme.mono(color).copyWith(
      fontSize: 13.5,
      height: base.height,
      backgroundColor: color.withValues(alpha: 0.08),
    ),
    // CodeBlock pads its own header and body.
    codeblockPadding: EdgeInsets.zero,
    codeblockDecoration: BoxDecoration(
      color: codeBackground,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: borderColor),
    ),
    blockquote: base.copyWith(color: color.withValues(alpha: 0.78)),
    blockquotePadding: const EdgeInsets.only(left: 10),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          color: color.withValues(alpha: 0.45),
          width: 3,
        ),
      ),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: borderColor)),
    ),
  );
}

/// Renders fenced code blocks as [CodeBlock]s. Registered for `pre`, so the
/// markdown builder still wraps the result in the style sheet's
/// `codeblockDecoration` frame.
class CodeBlockBuilder extends MarkdownElementBuilder {
  CodeBlockBuilder(this.color);

  final Color color;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    String? language;
    final md.Node? code = element.children?.firstOrNull;
    if (code is md.Element) {
      final String? cls = code.attributes['class'];
      if (cls != null && cls.startsWith('language-')) {
        language = cls.substring('language-'.length);
      }
    }
    return CodeBlock(
      code: element.textContent.replaceFirst(RegExp(r'\n$'), ''),
      language: language,
      color: color,
    );
  }
}

class CodeBlock extends StatefulWidget {
  const CodeBlock({
    required this.code,
    required this.color,
    this.language,
    super.key,
  });

  final String code;
  final String? language;
  final Color color;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  TextSpan? _span;
  Brightness? _spanBrightness;
  bool _copied = false;
  Timer? _copiedReset;

  @override
  void didUpdateWidget(CodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code ||
        oldWidget.language != widget.language ||
        oldWidget.color != widget.color) {
      _span = null;
    }
  }

  @override
  void dispose() {
    _copiedReset?.cancel();
    super.dispose();
  }

  TextSpan _highlighted(Brightness brightness) {
    if (_span != null && _spanBrightness == brightness) return _span!;
    final TextStyle base = AppTheme.mono(widget.color);
    final String? language = widget.language;
    TextSpan span = TextSpan(text: widget.code, style: base);
    if (language != null &&
        widget.code.length <= maxHighlightedChars &&
        _highlighter.getLanguage(language) != null) {
      final TextSpanRenderer renderer = TextSpanRenderer(
        null,
        brightness == Brightness.dark ? githubDarkTheme : githubTheme,
      );
      _highlighter
          .highlight(code: widget.code, language: language)
          .render(renderer);
      final TextSpan? rendered = renderer.span;
      if (rendered != null) {
        span = TextSpan(style: base, children: <TextSpan>[rendered]);
      }
    }
    _spanBrightness = brightness;
    return _span = span;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedReset?.cancel();
    _copiedReset = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final Color muted = widget.color.withValues(alpha: 0.6);
    final String label = widget.language?.toLowerCase() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          height: 32,
          padding: const EdgeInsets.only(left: 12, right: 2),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: widget.color.withValues(alpha: 0.12)),
            ),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mono(muted).copyWith(fontSize: 11.5),
                ),
              ),
              IconButton(
                onPressed: _copy,
                tooltip: _copied ? context.l10n.copied : context.l10n.copy,
                iconSize: 15,
                visualDensity: VisualDensity.compact,
                color: muted,
                icon: Icon(
                  _copied ? Icons.check_rounded : Icons.content_copy_rounded,
                ),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Text.rich(
            _highlighted(Theme.of(context).brightness),
            softWrap: false,
          ),
        ),
      ],
    );
  }
}
