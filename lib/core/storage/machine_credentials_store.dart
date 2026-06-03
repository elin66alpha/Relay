import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/machine_credential.dart';

class MachineCredentialsStore {
  MachineCredentialsStore({
    FlutterSecureStorage? secureStorage,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const String _credentialsKey = 'relay.machine_credentials.v1';
  static const String _activeMachineKey = 'relay.active_machine_id.v1';

  final FlutterSecureStorage _secureStorage;

  Future<List<MachineCredential>> readAll() async {
    final String? raw = await _secureStorage.read(key: _credentialsKey);
    if (raw == null || raw.trim().isEmpty) return <MachineCredential>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map(
              (Map item) => MachineCredential.fromJson(
                item.cast<String, Object?>(),
              ),
            )
            .where(_isUsable)
            .toList(growable: false);
      }
    } on FormatException {
      return <MachineCredential>[];
    }
    return <MachineCredential>[];
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
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeMachineKey);
  }

  Future<void> upsert(
    MachineCredential credential, {
    bool makeActive = true,
  }) async {
    credential.validate();
    final List<MachineCredential> credentials =
        await readAll().then((List<MachineCredential> list) {
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
    if (makeActive) {
      await setActive(credential.id);
    }
  }

  Future<void> setActive(String id) async {
    final List<MachineCredential> credentials = await readAll();
    if (!credentials.any((MachineCredential item) => item.id == id)) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeMachineKey, id);
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
  }

  Future<void> _writeAll(List<MachineCredential> credentials) async {
    if (credentials.isEmpty) {
      await _secureStorage.delete(key: _credentialsKey);
      return;
    }
    await _secureStorage.write(
      key: _credentialsKey,
      value: jsonEncode(
        credentials.map((MachineCredential item) => item.toJson()).toList(),
      ),
    );
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
