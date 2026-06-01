import 'download_save_result.dart';
import 'file_saver_stub.dart'
    if (dart.library.html) 'file_saver_web.dart' as platform;

export 'download_save_result.dart';

/// Streams a download to the system Downloads folder without prompting for a
/// location. The byte stream is written straight to its destination (a file on
/// native, a blob on web) so a large download is never buffered whole in memory.
/// [onProgress] reports (received, total); [total] is null when unknown.
/// Returns where it was saved so the caller can show it.
Future<DownloadSaveResult> saveDownloadStream({
  required String fileName,
  required int? total,
  required Stream<List<int>> bytes,
  required void Function(int received, int? total) onProgress,
}) =>
    platform.saveDownloadStream(
      fileName: fileName,
      total: total,
      bytes: bytes,
      onProgress: onProgress,
    );
