import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/wallpaper_processor.dart';
import 'wallpaper.dart';

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
  static const String _wallpaperKey = 'relay.wallpaper.v2';
  Wallpaper _wallpaper = const Wallpaper();
  // What the settings entry stores for the image: a file name, or base64 on Web.
  String? _wallpaperImage;
  Wallpaper get wallpaper => _wallpaper;

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
    final String? stored = prefs.getString(_wallpaperKey);
    _wallpaperImage = null;
    if (stored == null) {
      _wallpaper = const Wallpaper();
    } else {
      try {
        final Map<String, dynamic> data =
            jsonDecode(stored) as Map<String, dynamic>;
        final Object? image = data['image'];
        final Uint8List? bytes =
            await loadWallpaperImage(image is String ? image : null);
        _wallpaperImage = bytes == null ? null : image as String;
        _wallpaper = Wallpaper(
          bytes: bytes,
          lightOpacity:
              _wallpaperOpacity((data['light'] as num?)?.toDouble() ?? 0.8),
          darkOpacity:
              _wallpaperOpacity((data['dark'] as num?)?.toDouble() ?? 0.2),
          blur: _wallpaperBlur(
            (data['blur'] as num?)?.toDouble() ?? Wallpaper.defaultBlur,
          ),
          tint: _wallpaperOpacity(
            (data['tint'] as num?)?.toDouble() ?? Wallpaper.defaultTint,
          ),
        );
      } catch (_) {
        // Damaged local image data must not prevent application startup.
        _wallpaper = const Wallpaper();
      }
    }
    notifyListeners();
  }

  /// Persists the prepared image, both theme opacities and the acrylic look in
  /// one replacement.
  Future<void> saveWallpaper(Wallpaper value) async {
    final Wallpaper normalized = Wallpaper(
      bytes: value.bytes,
      lightOpacity: _wallpaperOpacity(value.lightOpacity),
      darkOpacity: _wallpaperOpacity(value.darkOpacity),
      blur: _wallpaperBlur(value.blur),
      tint: _wallpaperOpacity(value.tint),
    );
    // An opacity-only change keeps the stored image instead of copying it again.
    final String? image = identical(value.bytes, _wallpaper.bytes)
        ? _wallpaperImage
        : await storeWallpaperImage(value.bytes);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    bool saved = false;
    try {
      saved = await prefs.setString(
        _wallpaperKey,
        _encodeWallpaper(image, normalized),
      );
    } finally {
      // Only the image the settings point to is kept, even after a failure.
      await discardWallpaperImages(keep: saved ? image : _wallpaperImage);
    }
    if (!saved) throw StateError('wallpaper storage');
    _wallpaperImage = image;
    _wallpaper = normalized;
    notifyListeners();
  }

  String _encodeWallpaper(String? image, Wallpaper value) =>
      jsonEncode(<String, Object?>{
        'image': image,
        'light': value.lightOpacity,
        'dark': value.darkOpacity,
        'blur': value.blur,
        'tint': value.tint,
      });

  double _wallpaperOpacity(double value) =>
      value.isFinite ? value.clamp(0.0, 1.0).toDouble() : 0.0;

  double _wallpaperBlur(double value) => value.isFinite
      ? value.clamp(0.0, Wallpaper.maxBlur).toDouble()
      : Wallpaper.defaultBlur;

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
