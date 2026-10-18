import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'wallpaper_processor_common.dart';

/// Native platforms keep the original file at full resolution.
const int? wallpaperImportLimit = null;

Future<Uint8List> prepareWallpaper(Uint8List bytes) async {
  try {
    wallpaperInfo(bytes);
    return bytes;
  } catch (_) {
    throw const FormatException('wallpaper image');
  }
}

final RegExp _storedName = RegExp(r'^wallpaper-\d+$');

Future<Directory> _wallpaperDirectory() async => Directory(
      '${(await getApplicationSupportDirectory()).path}'
      '${Platform.pathSeparator}wallpaper',
    );

// File access is synchronous: it runs only on Save and at launch.
// shortcut: a very large image briefly blocks frames while it is copied; move
// this to an isolate if that is ever noticeable.

/// Copies the image into the app directory; settings keep only its file name.
Future<String?> storeWallpaperImage(Uint8List? bytes) async {
  if (bytes == null) return null;
  final Directory directory = await _wallpaperDirectory();
  directory.createSync(recursive: true);
  final String name = 'wallpaper-${DateTime.now().microsecondsSinceEpoch}';
  File('${directory.path}${Platform.pathSeparator}$name')
      .writeAsBytesSync(bytes, flush: true);
  return name;
}

Future<Uint8List?> loadWallpaperImage(String? stored) async {
  if (stored == null || !_storedName.hasMatch(stored)) return null;
  final File file = File(
    '${(await _wallpaperDirectory()).path}${Platform.pathSeparator}$stored',
  );
  return file.existsSync() ? file.readAsBytesSync() : null;
}

/// Deletes every stored image except [keep], the one settings point to.
Future<void> discardWallpaperImages({String? keep}) async {
  final Directory directory = await _wallpaperDirectory();
  if (!directory.existsSync()) return;
  for (final FileSystemEntity entry in directory.listSync()) {
    if (entry is File && entry.uri.pathSegments.last != keep) {
      try {
        entry.deleteSync();
      } on FileSystemException {
        // Best effort: a leftover file is removed by the next save.
      }
    }
  }
}
