/// Web has nothing to install: the backend serves the client.
Future<void> downloadAndInstall(
  Uri uri,
  String asset,
  void Function(double? progress) onProgress,
) =>
    throw UnsupportedError('This platform cannot update itself.');
