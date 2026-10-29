import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DeviceIdStore {
  DeviceIdStore({FlutterSecureStorage? secureStorage, Random? random})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
      _random = random ?? Random.secure();

  static const String _deviceIdKey = 'relay.device_id.v1';
  static String? _cachedId;

  final FlutterSecureStorage _secureStorage;
  final Random _random;

  static void resetCacheForTest() {
    _cachedId = null;
  }

  Future<String> readOrCreate() async {
    if (_isValid(_cachedId)) return _cachedId!.trim();

    final String? existing = await _secureStorage.read(key: _deviceIdKey);
    if (_isValid(existing)) {
      _cachedId = existing!.trim();
      return _cachedId!;
    }

    final String created = _newDeviceId();
    await _secureStorage.write(key: _deviceIdKey, value: created);
    _cachedId = created;
    return created;
  }

  bool _isValid(String? value) {
    final String text = value?.trim() ?? '';
    return RegExp(r'^[A-Za-z0-9._-]{8,128}$').hasMatch(text);
  }

  String _newDeviceId() {
    final List<int> bytes = List<int>.generate(18, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
