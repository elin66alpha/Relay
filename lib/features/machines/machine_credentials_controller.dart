import 'package:flutter/foundation.dart';

import '../../core/credentials/credential_file_codec.dart';
import '../../core/models/machine_credential.dart';
import '../../core/storage/machine_credentials_store.dart';

Future<MachineCredential> _decryptCredentialBytesInBackground(
  Map<String, Object?> input,
) {
  return CredentialFileCodec().decrypt(
    input['bytes']! as Uint8List,
    passphrase: input['passphrase']! as String,
  );
}

class MachineCredentialsController extends ChangeNotifier {
  MachineCredentialsController({
    MachineCredentialsStore? store,
    CredentialFileCodec? codec,
  }) : _store = store ?? MachineCredentialsStore(),
       _codec = codec ?? CredentialFileCodec();

  final MachineCredentialsStore _store;
  final CredentialFileCodec _codec;

  List<MachineCredential> _credentials = <MachineCredential>[];
  String? _activeMachineId;
  bool _isLoaded = false;

  List<MachineCredential> get credentials =>
      List<MachineCredential>.unmodifiable(_credentials);
  String? get activeMachineId => _activeMachineId;
  bool get isLoaded => _isLoaded;

  MachineCredential? get activeMachine {
    if (_credentials.isEmpty) return null;
    for (final MachineCredential credential in _credentials) {
      if (credential.id == _activeMachineId) return credential;
    }
    return _credentials.first;
  }

  Future<void> load() async {
    _credentials = await _store.readAll();
    _activeMachineId = await _store.readActiveId();
    if (!_credentials.any(
      (MachineCredential item) => item.id == _activeMachineId,
    )) {
      _activeMachineId = _credentials.isEmpty ? null : _credentials.first.id;
      if (_activeMachineId != null) {
        await _store.setActive(_activeMachineId!);
      }
    }
    _isLoaded = true;
    notifyListeners();
  }

  Future<MachineCredential> importEncryptedBytes(
    Uint8List bytes, {
    required String passphrase,
  }) async {
    final MachineCredential credential = await decryptEncryptedBytes(
      bytes,
      passphrase: passphrase,
    );
    await saveCredential(credential);
    return credential;
  }

  Future<MachineCredential> decryptEncryptedBytes(
    Uint8List bytes, {
    required String passphrase,
  }) async {
    if (!kIsWeb && _codec.runtimeType == CredentialFileCodec) {
      return compute(_decryptCredentialBytesInBackground, <String, Object?>{
        'bytes': bytes,
        'passphrase': passphrase,
      });
    }
    return _codec.decrypt(bytes, passphrase: passphrase);
  }

  Future<void> saveCredential(MachineCredential credential) async {
    await _store.upsert(credential);
    await load();
  }

  Future<void> setActive(String id) async {
    if (_activeMachineId == id) return;
    await _store.setActive(id);
    await load();
  }

  Future<void> delete(String id) async {
    await _store.delete(id);
    await load();
  }
}
