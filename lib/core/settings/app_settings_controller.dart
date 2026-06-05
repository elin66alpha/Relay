import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage { en, zh }

class AppSettingsController extends ChangeNotifier {
  static const String _languageKey = 'relay.language.v1';
  static const String _themeKey = 'relay.theme_mode.v1';
  static const String _quotaPushKey = 'relay.push.quota.v1';
  static const String _taskPushKey = 'relay.push.task.v1';

  AppLanguage _language = AppLanguage.en;
  ThemeMode _themeMode = ThemeMode.system;
  bool _quotaPushEnabled = true;
  bool _taskPushEnabled = true;

  AppLanguage get language => _language;
  ThemeMode get themeMode => _themeMode;
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
}
