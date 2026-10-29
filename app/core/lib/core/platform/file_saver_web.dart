import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'download_save_result.dart';

/// On web the browser owns the save location; a Blob needs the full bytes, so we
/// accumulate the stream (reporting progress) and then trigger an anchor
/// download into the browser's downloads folder.
Future<DownloadSaveResult> saveDownloadStream({
  required String fileName,
  required int? total,
  required Stream<List<int>> bytes,
  required void Function(int received, int? total) onProgress,
}) async {
  final BytesBuilder builder = BytesBuilder(copy: false);
  int received = 0;
  onProgress(0, total);
  await for (final List<int> chunk in bytes) {
    builder.add(chunk);
    received += chunk.length;
    onProgress(received, total);
  }
  final web.Blob blob = web.Blob(<JSAny>[builder.takeBytes().toJS].toJS);
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
