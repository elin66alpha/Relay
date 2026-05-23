import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage { en, zh }

class AppSettingsController extends ChangeNotifier {
  static const String _languageKey = 'agentdeck.language.v1';
  static const String _themeKey = 'agentdeck.theme_mode.v1';

  AppLanguage _language = AppLanguage.en;
  ThemeMode _themeMode = ThemeMode.system;

  AppLanguage get language => _language;
  ThemeMode get themeMode => _themeMode;

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
}
