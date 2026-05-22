import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage { en, zh }

enum SttLanguage { auto, zh, en }

extension SttLanguageValue on SttLanguage {
  String get apiValue {
    return switch (this) {
      SttLanguage.zh => 'zh',
      SttLanguage.en => 'en',
      SttLanguage.auto => 'auto',
    };
  }
}

class AppSettingsController extends ChangeNotifier {
  static const String _languageKey = 'agentdeck.language.v1';
  static const String _themeKey = 'agentdeck.theme_mode.v1';
  static const String _sttLanguageKey = 'agentdeck.stt_language.v1';

  AppLanguage _language = AppLanguage.en;
  ThemeMode _themeMode = ThemeMode.system;
  SttLanguage _sttLanguage = SttLanguage.auto;

  AppLanguage get language => _language;
  ThemeMode get themeMode => _themeMode;
  SttLanguage get sttLanguage => _sttLanguage;

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
    _sttLanguage = switch (prefs.getString(_sttLanguageKey)) {
      'zh' => SttLanguage.zh,
      'en' => SttLanguage.en,
      _ => SttLanguage.auto,
    };
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

  Future<void> setSttLanguage(SttLanguage value) async {
    if (_sttLanguage == value) return;
    _sttLanguage = value;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sttLanguageKey, value.name);
    notifyListeners();
  }
}
