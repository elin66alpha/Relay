/// Where a downloaded file ended up, so the UI can tell the user exactly where
/// to find it. On native platforms [path] is the absolute file path. On web the
/// browser owns the save location, so [isBrowserDownload] is true and [path] is
/// the browser's downloads folder (a display label, not a real filesystem path).
class DownloadSaveResult {
  const DownloadSaveResult({
    this.path,
    this.isBrowserDownload = false,
  });

  final String? path;
  final bool isBrowserDownload;
}
