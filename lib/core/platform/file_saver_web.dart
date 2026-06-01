import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'download_save_result.dart';

/// On web the browser saves to its own downloads folder; we can't choose the
/// path. We trigger the download via an anchor click and report it as a browser
/// download so the UI shows "saved to your browser's downloads folder".
Future<DownloadSaveResult> saveDownloadedFile({
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
  return const DownloadSaveResult(isBrowserDownload: true);
}
