import 'dart:convert';
import 'dart:typed_data';

import 'package:relay/core/credentials/credential_file_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decrypts Node-generated credential file', () async {
    const String raw = '''
{
  "format": "relay.credentials.v1",
  "kdf": {
    "name": "pbkdf2-sha256",
    "iterations": 210000,
    "salt": "SndGsny3sRtbyhYQpbiPHA=="
  },
  "cipher": {
    "name": "aes-256-gcm",
    "nonce": "5N6ibbZzR27TAQvk",
    "tag": "a5Eqv0zK21lZZMsSNRV5Vg==",
    "ciphertext": "4Xz1oDBb+DI1+6+sXr65avGDtJSRxCsRp3XzZ3x14FhuNdIm47Lbh2P5cpOt1TKi+D2sVPMqYkgTiezPh2AzzytD6HbjB81aAfKz1/oZ1BqFBgGMNu0s0PNqDEKw0Nvw0/WWJ94m68kpJ1ZP9BePygBgAkuBZ3KZqv34mrSnjU7Uf8yMcOuRLqC3ENA8kdp97MVH8H2wvZlIeXt1lT71gZcCQQwkH514wDn7mmheUiWUakVbPMv3mx3Y"
  }
}
''';

    final credential = await CredentialFileCodec().decrypt(
      Uint8List.fromList(utf8.encode(raw)),
      passphrase: 'test-passphrase',
    );

    expect(credential.id, 'test-machine');
    expect(credential.name, 'Test Machine');
    expect(credential.baseUrl, 'https://example.com');
    expect(credential.token, 'test-token');
  });
}
