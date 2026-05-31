import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

Future<String?> saveDownloadedFile({
  required String fileName,
  required Uint8List bytes,
}) =>
    FilePicker.saveFile(fileName: fileName, bytes: bytes);
