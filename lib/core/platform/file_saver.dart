import 'dart:typed_data';

import 'download_save_result.dart';
import 'file_saver_stub.dart'
    if (dart.library.html) 'file_saver_web.dart' as platform;

export 'download_save_result.dart';

/// Saves a downloaded file to the system Downloads folder without prompting the
/// user for a location. Returns where it was saved so the caller can show it.
Future<DownloadSaveResult> saveDownloadedFile({
  required String fileName,
  required Uint8List bytes,
}) =>
    platform.saveDownloadedFile(fileName: fileName, bytes: bytes);
