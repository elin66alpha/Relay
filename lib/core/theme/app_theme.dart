import 'package:flutter/material.dart';

class AppTheme {
  /// The bundled monospace family, used wherever text is code or an
  /// identifier: chat code, model ids, paths, and the SSH terminal.
  static const String monoFamily = 'RelayTerminalMono';

  /// Platform monospace and CJK/emoji fallbacks for [monoFamily], which only
  /// covers Latin glyphs.
  static const List<String> monoFallback = <String>[
    'Cascadia Mono',
    'Consolas',
    'Menlo',
    'Monaco',
    'Liberation Mono',
    'DejaVu Sans Mono',
    'Noto Sans Mono',
    'Noto Sans Mono CJK SC',
    'Noto Sans Mono CJK TC',
    'Noto Sans Mono CJK KR',
    'Noto Sans Mono CJK JP',
    'Noto Color Emoji',
    'Noto Sans Symbols',
    'monospace',
  ];

  /// Text in [monoFamily]: code, paths, ids, numbers and times.
  static TextStyle mono(Color color) => TextStyle(
        color: color,
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontSize: 13,
        height: 1.5,
      );

  /// Corner radius of panels (cards, agent replies, code blocks).
  static const double panelRadius = 12;

  /// Status colours that must read the same in both themes.
  static const Color statusOk = Color(0xFF10B981);
  static const Color statusDown = Color(0xFFEF4444);
  static const Color statusWarn = Color(0xFFF59E0B);

  static ThemeData light() {
    const Color seed = Color(0xFF0B84FF);
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
    );
    return _base(scheme, panel: Colors.white).copyWith(
      scaffoldBackgroundColor: const Color(0xFFF3F7FB),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: Color(0xFFF3F7FB),
        foregroundColor: Color(0xFF101923),
      ),
    );
  }

  static ThemeData dark() {
    const Color seed = Color(0xFF00D5FF);
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    return _base(scheme, panel: const Color(0xFF0D1823)).copyWith(
      scaffoldBackgroundColor: const Color(0xFF071019),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: Color(0xFF071019),
        foregroundColor: Color(0xFFEAF6FF),
      ),
    );
  }

  /// [panel] is the raised surface for cards and agent replies: a step lighter
  /// than the scaffold, edged by a hairline instead of a shadow.
  static ThemeData _base(ColorScheme scheme, {required Color panel}) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      cardTheme: CardThemeData(
        elevation: 0,
        color: panel,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(panelRadius),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.7)),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 450),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.primary),
        ),
      ),
    );
  }
}
