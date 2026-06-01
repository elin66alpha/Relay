import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'download_save_result.dart';

/// Talks to the Android side, which writes into the shared MediaStore Downloads
/// collection (the folder the system "Files"/"Downloads" app shows).
const MethodChannel _downloadsChannel =
    MethodChannel('dev.agentdeck.app/downloads');

/// Native save: Android goes through MediaStore so files land in the real
/// Downloads folder; desktop uses the OS Downloads directory; iOS falls back to
/// the app documents directory (it has no shared Downloads folder). No picker is
/// shown — the location is fixed and returned to the caller.
Future<DownloadSaveResult> saveDownloadedFile({
  required String fileName,
  required Uint8List bytes,
}) async {
  final String safeName = _sanitizeName(fileName);

  if (defaultTargetPlatform == TargetPlatform.android) {
    final String? saved = await _downloadsChannel.invokeMethod<String>(
      'saveToDownloads',
      <String, Object?>{
        'fileName': safeName,
        'bytes': bytes,
      },
    );
    return DownloadSaveResult(path: saved ?? 'Download/$safeName');
  }

  final Directory dir = await _targetDirectory();
  final String fullPath = await _uniquePath(dir, safeName);
  await File(fullPath).writeAsBytes(bytes, flush: true);
  return DownloadSaveResult(path: fullPath);
}

Future<Directory> _targetDirectory() async {
  Directory? dir;
  try {
    dir = await getDownloadsDirectory();
  } catch (_) {
    dir = null;
  }
  dir ??= await getApplicationDocumentsDirectory();
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// Avoid clobbering an existing file: "report.zip" -> "report (1).zip".
Future<String> _uniquePath(Directory dir, String name) async {
  final String sep = Platform.pathSeparator;
  String candidate = '${dir.path}$sep$name';
  if (!await File(candidate).exists()) return candidate;
  final int dot = name.lastIndexOf('.');
  final String stem = dot > 0 ? name.substring(0, dot) : name;
  final String ext = dot > 0 ? name.substring(dot) : '';
  for (int i = 1; i < 1000; i++) {
    candidate = '${dir.path}$sep$stem ($i)$ext';
    if (!await File(candidate).exists()) return candidate;
  }
  return candidate;
}

String _sanitizeName(String name) {
  final String base = name.split(RegExp(r'[\\/]')).last.trim();
  final String cleaned = base.replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
  return cleaned.isEmpty ? 'download' : cleaned;
}
