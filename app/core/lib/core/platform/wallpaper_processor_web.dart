import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:web/web.dart' as web;

import 'wallpaper_processor_common.dart';

/// Web stores the image inline in localStorage, so it is bounded.
const int wallpaperImportLimit = 20 * 1024 * 1024;
const int maxWallpaperStoredBytes = 256 * 1024;
const int maxWallpaperEdge = 1920;

/// Browser decoding and JPEG encoding yield while the loading indicator paints.
Future<Uint8List> prepareWallpaper(Uint8List bytes) async {
  try {
    if (bytes.length > wallpaperImportLimit) {
      throw const FormatException('wallpaper size');
    }
    final img.DecodeInfo info = wallpaperInfo(bytes);
    if (info.width * info.height > 40000000) {
      throw const FormatException('wallpaper image');
    }
    final web.Blob source = web.Blob(<JSAny>[bytes.toJS].toJS);
    final web.ImageBitmap bitmap =
        await web.window.createImageBitmap(source).toDart;
    final web.HTMLCanvasElement canvas = web.HTMLCanvasElement();
    try {
      final double scale =
          math.min(1, maxWallpaperEdge / math.max(bitmap.width, bitmap.height));
      int width = math.max(1, (bitmap.width * scale).round());
      int height = math.max(1, (bitmap.height * scale).round());
      while (true) {
        canvas.width = width;
        canvas.height = height;
        final web.CanvasRenderingContext2D paint =
            canvas.getContext('2d')! as web.CanvasRenderingContext2D;
        paint.fillStyle = '#808080'.toJS;
        paint.fillRect(0, 0, width, height);
        paint.drawImage(bitmap, 0, 0, width, height);
        final Completer<web.Blob> encoded = Completer<web.Blob>();
        canvas.toBlob(
          ((web.Blob? result) {
            if (result == null) {
              encoded
                  .completeError(const FormatException('wallpaper encoding'));
            } else {
              encoded.complete(result);
            }
          }).toJS,
          'image/jpeg',
          0.86.toJS,
        );
        final web.Blob image = await encoded.future;
        if (image.size <= maxWallpaperStoredBytes) {
          return (await image.arrayBuffer().toDart).toDart.asUint8List();
        }
        width = math.max(1, (width * 0.8).round());
        height = math.max(1, (height * 0.8).round());
      }
    } finally {
      bitmap.close();
      canvas.width = 0;
      canvas.height = 0;
    }
  } catch (_) {
    throw const FormatException('wallpaper image');
  }
}

Future<String?> storeWallpaperImage(Uint8List? bytes) async =>
    bytes == null ? null : base64Encode(bytes);

Future<Uint8List?> loadWallpaperImage(String? stored) async =>
    stored == null ? null : base64Decode(stored);

Future<void> discardWallpaperImages({String? keep}) async {}
