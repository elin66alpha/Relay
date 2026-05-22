import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/machine_credential.dart';

class CredentialFileCodec {
  static const String format = 'agentdeck.credentials.v1';
  static const String kdfName = 'pbkdf2-sha256';
  static const String cipherName = 'aes-256-gcm';

  Future<MachineCredential> decrypt(
    Uint8List bytes, {
    required String passphrase,
  }) async {
    if (passphrase.trim().isEmpty) {
      throw const MachineCredentialException('Enter the credential password.');
    }

    final Map<String, Object?> envelope = _decodeJsonObject(bytes);
    if (envelope['format'] != format) {
      throw const MachineCredentialException(
        'This is not an encrypted AgentDeck credential.',
      );
    }

    final Map<String, Object?> kdf = _readObject(envelope['kdf'], 'kdf');
    final Map<String, Object?> cipher =
        _readObject(envelope['cipher'], 'cipher');
    if (kdf['name'] != kdfName || cipher['name'] != cipherName) {
      throw const MachineCredentialException(
        'The credential uses an unsupported encryption format.',
      );
    }

    final int iterations = _readInt(kdf['iterations'], 'iterations');
    if (iterations < 10000 || iterations > 2000000) {
      throw const MachineCredentialException(
        'The credential KDF parameters are outside the supported safety range.',
      );
    }

    final List<int> salt = _readBase64(kdf['salt'], 'salt');
    final List<int> nonce = _readBase64(cipher['nonce'], 'nonce');
    final List<int> tag = _readBase64(cipher['tag'], 'tag');
    final List<int> ciphertext = _readBase64(
      cipher['ciphertext'],
      'ciphertext',
    );

    try {
      final Pbkdf2 pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      );
      final SecretKey key = await pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode(passphrase)),
        nonce: salt,
      );
      final List<int> plaintext = await AesGcm.with256bits().decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(tag)),
        secretKey: key,
      );
      final Map<String, Object?> payload = _decodeJsonObject(
        Uint8List.fromList(plaintext),
      );
      final Object rawMachine = payload['machine'] ?? payload;
      final MachineCredential credential = MachineCredential.fromJson(
        _readObject(rawMachine, 'machine'),
      );
      credential.validate();
      return credential;
    } on MachineCredentialException {
      rethrow;
    } catch (_) {
      throw const MachineCredentialException(
        'Credential decryption failed. Check the QR code and password.',
      );
    }
  }

  Map<String, Object?> _decodeJsonObject(Uint8List bytes) {
    try {
      final Object? decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      throw const MachineCredentialException(
        'The credential is not valid JSON.',
      );
    }
    throw const MachineCredentialException(
      'The credential JSON structure is invalid.',
    );
  }

  Map<String, Object?> _readObject(Object? value, String field) {
    if (value is Map) return value.cast<String, Object?>();
    throw MachineCredentialException('The credential is missing $field.');
  }

  int _readInt(Object? value, String field) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw MachineCredentialException('The credential $field value is invalid.');
  }

  List<int> _readBase64(Object? value, String field) {
    if (value is! String || value.trim().isEmpty) {
      throw MachineCredentialException('The credential is missing $field.');
    }
    try {
      return base64Decode(value);
    } on FormatException {
      throw MachineCredentialException(
        'The credential $field value is not valid base64.',
      );
    }
  }
}
