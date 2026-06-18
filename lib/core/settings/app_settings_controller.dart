import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage { en, zh }

class AppSettingsController extends ChangeNotifier {
  static const String _languageKey = 'relay.language.v1';
  static const String _themeKey = 'relay.theme_mode.v1';
  static const String _fontScaleKey = 'relay.font_scale.v1';
  static const String _quotaPushKey = 'relay.push.quota.v1';
  static const String _taskPushKey = 'relay.push.task.v1';
  static const double minFontScale = 0.85;
  static const double maxFontScale = 1.30;
  static const double defaultFontScale = 1.0;

  AppLanguage _language = AppLanguage.en;
  ThemeMode _themeMode = ThemeMode.system;
  double _fontScale = defaultFontScale;
  int _fontScaleSaveGeneration = 0;
  bool _quotaPushEnabled = true;
  bool _taskPushEnabled = true;

  AppLanguage get language => _language;
  ThemeMode get themeMode => _themeMode;
  double get fontScale => _fontScale;
  bool get quotaPushEnabled => _quotaPushEnabled;
  bool get taskPushEnabled => _taskPushEnabled;

  Future<void> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _language = switch (prefs.getString(_languageKey)) {
      'zh' => AppLanguage.zh,
      _ => AppLanguage.en,
    };
    _themeMode = switch (prefs.getString(_themeKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    _fontScale = _normalizeFontScale(
      prefs.getDouble(_fontScaleKey) ?? defaultFontScale,
    );
    _quotaPushEnabled = prefs.getBool(_quotaPushKey) ?? true;
    _taskPushEnabled = prefs.getBool(_taskPushKey) ?? true;
    notifyListeners();
  }

  Future<void> setLanguage(AppLanguage value) async {
    if (_language == value) return;
    _language = value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, value.name);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode value) async {
    if (_themeMode == value) return;
    _themeMode = value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, value.name);
    notifyListeners();
  }

  Future<void> setFontScale(double value) async {
    final double normalized = _normalizeFontScale(value);
    if (_fontScale == normalized) return;
    final int generation = ++_fontScaleSaveGeneration;
    _fontScale = normalized;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (generation == _fontScaleSaveGeneration) {
      await prefs.setDouble(_fontScaleKey, normalized);
    }
  }

  Future<void> setQuotaPushEnabled(bool value) async {
    if (_quotaPushEnabled == value) return;
    _quotaPushEnabled = value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_quotaPushKey, value);
    notifyListeners();
  }

  Future<void> setTaskPushEnabled(bool value) async {
    if (_taskPushEnabled == value) return;
    _taskPushEnabled = value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_taskPushKey, value);
    notifyListeners();
  }

  double _normalizeFontScale(double value) {
    return value.clamp(minFontScale, maxFontScale).toDouble();
  }
}
