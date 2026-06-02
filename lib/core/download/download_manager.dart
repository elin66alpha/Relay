import 'package:flutter/foundation.dart';

import '../backend/backend_client.dart';
import '../i18n/app_strings.dart';
import '../notifications/notification_service.dart';
import '../platform/file_saver.dart';

enum DownloadStage { idle, downloading, saving, done, failed }

/// App-level download state so a transfer keeps running and reports its result
/// even after the user leaves the file browser. The download future is driven
/// here (not in a widget State), so navigating away no longer cancels progress
/// updates or the completion notification. The file browser just listens to this
/// to render live progress when it happens to be on screen.
class DownloadManager extends ChangeNotifier {
  DownloadManager._();

  static final DownloadManager instance = DownloadManager._();

  DownloadStage stage = DownloadStage.idle;
  String? fileName;
  int received = 0;
  int? total;
  String? savedLocation;
  String? errorText;

  /// Bumps once each time a download settles (done or failed) so a screen can
  /// show a one-shot snackbar without replaying it on every rebuild.
  int completedTick = 0;

  // Progress can fire once per network chunk; coalesce notifications to ~10/s so
  // listeners don't repaint on every chunk. Stage changes still notify instantly.
  static const Duration _progressInterval = Duration(milliseconds: 100);
  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isActive =>
      stage == DownloadStage.downloading || stage == DownloadStage.saving;

  /// Starts a download in the background. [open] begins the transfer; the byte
  /// stream is written straight to the system Downloads folder (to disk on
  /// native, never buffered whole) while progress is reported, and a system
  /// notification fires on completion regardless of which screen is visible.
  /// Only one download runs at a time.
  Future<void> startDownload({
    required String fileName,
    required AppStrings strings,
    required Future<FsDownloadStream> Function() open,
  }) async {
    if (isActive) return;
    this.fileName = fileName;
    received = 0;
    total = null;
    savedLocation = null;
    errorText = null;
    stage = DownloadStage.downloading;
    _lastProgressNotify = DateTime.now();
    notifyListeners();
    try {
      final FsDownloadStream download = await open();
      final DownloadSaveResult saved = await saveDownloadStream(
        fileName: download.fileName,
        total: download.total,
        bytes: download.bytes,
        onProgress: (int r, int? t) {
          received = r;
          total = t;
          if (stage != DownloadStage.downloading) return;
          final DateTime now = DateTime.now();
          if (now.difference(_lastProgressNotify) >= _progressInterval) {
            _lastProgressNotify = now;
            notifyListeners();
          }
        },
      );
      savedLocation = saved.isBrowserDownload
          ? strings.savedToBrowserDownloads
          : strings.savedTo(saved.path ?? download.fileName);
      stage = DownloadStage.done;
      completedTick++;
      notifyListeners();
      await NotificationService.instance.show(
        title: strings.downloadComplete,
        body: '${download.fileName}\n$savedLocation',
      );
    } catch (err) {
      errorText = err is BackendException && err.code == 'FS_DOWNLOAD_TOO_LARGE'
          ? strings.downloadTooLarge('300 MB')
          : strings.downloadFailed(err);
      stage = DownloadStage.failed;
      completedTick++;
      notifyListeners();
      await NotificationService.instance.show(
        title: strings.downloadFailedTitle,
        body: errorText!,
      );
    }
  }
}
