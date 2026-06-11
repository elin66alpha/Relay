import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/machine_credential.dart';

class MachineCredentialsStore {
  MachineCredentialsStore({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const String _credentialsKey = 'relay.machine_credentials.v1';
  static const String _activeMachineKey = 'relay.active_machine_id.v1';
  static List<MachineCredential>? _cachedCredentials;
  static bool _activeIdLoaded = false;
  static String? _cachedActiveId;

  final FlutterSecureStorage _secureStorage;

  static void resetCacheForTest() => _invalidateCache();

  // The cache is static (shared by every store instance), so any write must
  // drop it for all readers — BackendClient and CardsService hold their own
  // instances of this store.
  static void _invalidateCache() {
    _cachedCredentials = null;
    _activeIdLoaded = false;
    _cachedActiveId = null;
  }

  Future<List<MachineCredential>> readAll() async {
    final List<MachineCredential>? cached = _cachedCredentials;
    if (cached != null) return cached;

    final String? raw = await _secureStorage.read(key: _credentialsKey);
    if (raw == null || raw.trim().isEmpty) {
      _cachedCredentials = const <MachineCredential>[];
      return _cachedCredentials!;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        _cachedCredentials = List<MachineCredential>.unmodifiable(
          decoded
              .whereType<Map>()
              .map(
                (Map item) =>
                    MachineCredential.fromJson(item.cast<String, Object?>()),
              )
              .where(_isUsable),
        );
        return _cachedCredentials!;
      }
    } on FormatException {
      _cachedCredentials = const <MachineCredential>[];
      return _cachedCredentials!;
    }
    _cachedCredentials = const <MachineCredential>[];
    return _cachedCredentials!;
  }

  Future<MachineCredential?> readActive() async {
    final List<MachineCredential> credentials = await readAll();
    if (credentials.isEmpty) return null;
    final String? activeId = await readActiveId();
    for (final MachineCredential credential in credentials) {
      if (credential.id == activeId) return credential;
    }
    return credentials.first;
  }

  Future<String?> readActiveId() async {
    if (_activeIdLoaded) return _cachedActiveId;

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _cachedActiveId = prefs.getString(_activeMachineKey);
    _activeIdLoaded = true;
    return _cachedActiveId;
  }

  Future<void> upsert(
    MachineCredential credential, {
    bool makeActive = true,
  }) async {
    credential.validate();
    final List<MachineCredential> credentials = await readAll().then((
      List<MachineCredential> list,
    ) {
      final List<MachineCredential> mutable = list.toList(growable: true);
      final int index = mutable.indexWhere(
        (MachineCredential item) => item.id == credential.id,
      );
      if (index == -1) {
        mutable.add(credential);
      } else {
        mutable[index] = credential;
      }
      mutable.sort(
        (MachineCredential a, MachineCredential b) =>
            a.displayName.compareTo(b.displayName),
      );
      return mutable;
    });
    await _writeAll(credentials);
    _invalidateCache();
    if (makeActive) {
      await setActive(credential.id);
    }
  }

  Future<void> setActive(String id) async {
    final List<MachineCredential> credentials = await readAll();
    if (!credentials.any((MachineCredential item) => item.id == id)) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeMachineKey, id);
    _invalidateCache();
  }

  Future<void> delete(String id) async {
    final List<MachineCredential> credentials = (await readAll())
        .where((MachineCredential item) => item.id != id)
        .toList();
    await _writeAll(credentials);

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? activeId = prefs.getString(_activeMachineKey);
    if (activeId == id) {
      if (credentials.isEmpty) {
        await prefs.remove(_activeMachineKey);
      } else {
        await prefs.setString(_activeMachineKey, credentials.first.id);
      }
    }
    _invalidateCache();
  }

  Future<void> _writeAll(List<MachineCredential> credentials) async {
    if (credentials.isEmpty) {
      await _secureStorage.delete(key: _credentialsKey);
      _invalidateCache();
      return;
    }
    await _secureStorage.write(
      key: _credentialsKey,
      value: jsonEncode(
        credentials.map((MachineCredential item) => item.toJson()).toList(),
      ),
    );
    _invalidateCache();
  }

  bool _isUsable(MachineCredential credential) {
    try {
      credential.validate();
      return true;
    } on MachineCredentialException {
      return false;
    }
  }
}
