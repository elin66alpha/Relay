import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<String?> saveDownloadedFile({
  required String fileName,
  required Uint8List bytes,
}) async {
  final web.Blob blob = web.Blob(<JSAny>[bytes.toJS].toJS);
  final String url = web.URL.createObjectURL(blob);
  try {
    web.HTMLAnchorElement()
      ..href = url
      ..download = fileName
      ..click();
  } finally {
    web.URL.revokeObjectURL(url);
  }
  return null;
}
