import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'download_save_result.dart';

/// Talks to the Android side, which streams a file into the shared MediaStore
/// Downloads collection (the folder the system "Files"/"Downloads" app shows).
const MethodChannel _downloadsChannel =
    MethodChannel('dev.relay.app/downloads');

/// Native save: the download is streamed to a temp file first so we never hold
/// the whole thing in memory (a 300 MB download must not OOM a phone). The temp
/// file is then moved into place — Android imports it into MediaStore Downloads,
/// desktop/iOS moves it into the OS Downloads / documents directory. No picker
/// is shown; the final location is returned to the caller.
Future<DownloadSaveResult> saveDownloadStream({
  required String fileName,
  required int? total,
  required Stream<List<int>> bytes,
  required void Function(int received, int? total) onProgress,
}) async {
  final String safeName = _sanitizeName(fileName);
  final Directory tmpDir = await getTemporaryDirectory();
  final File tmp = File(
    '${tmpDir.path}${Platform.pathSeparator}'
    'relay_dl_${DateTime.now().microsecondsSinceEpoch}',
  );

  int received = 0;
  onProgress(0, total);
  final IOSink sink = tmp.openWrite();
  try {
    await for (final List<int> chunk in bytes) {
      sink.add(chunk);
      received += chunk.length;
      onProgress(received, total);
    }
    await sink.flush();
    await sink.close();
  } catch (_) {
    await sink.close();
    await _deleteQuietly(tmp);
    rethrow;
  }

  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final String? saved =
          await _downloadsChannel.invokeMethod<String>('importToDownloads', {
        'srcPath': tmp.path,
        'fileName': safeName,
      });
      return DownloadSaveResult(path: saved ?? 'Download/$safeName');
    }
    final Directory dir = await _targetDirectory();
    final String fullPath = await _uniquePath(dir, safeName);
    await _moveFile(tmp, fullPath);
    return DownloadSaveResult(path: fullPath);
  } finally {
    await _deleteQuietly(tmp);
  }
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

/// Rename when possible (same filesystem); fall back to copy for cross-device
/// moves (e.g. temp dir and Downloads on different mounts).
Future<void> _moveFile(File src, String destPath) async {
  try {
    await src.rename(destPath);
  } on FileSystemException {
    await src.copy(destPath);
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best effort: a leftover temp file is harmless.
  }
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
