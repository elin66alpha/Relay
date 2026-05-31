import 'dart:typed_data';

import 'file_saver_stub.dart' if (dart.library.html) 'file_saver_web.dart'
    as platform;

Future<String?> saveDownloadedFile({
  required String fileName,
  required Uint8List bytes,
}) =>
    platform.saveDownloadedFile(fileName: fileName, bytes: bytes);
