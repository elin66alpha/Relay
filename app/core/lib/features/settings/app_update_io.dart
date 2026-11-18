import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<void> downloadAndInstall(
  Uri uri,
  String asset,
  void Function(double? progress) onProgress,
) async {
  // Linux and macOS leave the file where the user finds it again; Android and
  // Windows consume it at once.
  final Directory dir = (Platform.isLinux || Platform.isMacOS
          ? await getDownloadsDirectory()
          : null) ??
      await getTemporaryDirectory();
  final File file = File(p.join(dir.path, asset));
  final http.Client client = http.Client();
  try {
    final http.StreamedResponse response =
        await client.send(http.Request('GET', uri));
    if (response.statusCode != 200) {
      throw http.ClientException('HTTP ${response.statusCode}', uri);
    }
    final int total = response.contentLength ?? 0;
    int received = 0;
    onProgress(total > 0 ? 0 : null);
    final IOSink sink = file.openWrite();
    try {
      await for (final List<int> chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
    } finally {
      await sink.close();
    }
  } finally {
    client.close();
  }

  if (Platform.isWindows) {
    await Process.start(
      'powershell.exe',
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        windowsReplaceScript(
          pid: pid,
          archive: file.path,
          executable: Platform.resolvedExecutable,
        ),
      ],
      mode: ProcessStartMode.detached,
    );
    exit(0);
  }
  final OpenResult result = await OpenFilex.open(file.path);
  if (result.type != ResultType.done) {
    throw FileSystemException(result.message, file.path);
  }
}

/// The Windows release is a ZIP of the app folder, and a running program's
/// files cannot be replaced. This PowerShell waits for the app to exit,
/// unpacks the ZIP over the folder the app runs from and starts it again.
String windowsReplaceScript({
  required int pid,
  required String archive,
  required String executable,
}) {
  String quote(String value) => "'${value.replaceAll("'", "''")}'";
  return 'Wait-Process -Id $pid -ErrorAction SilentlyContinue; '
      'Expand-Archive -LiteralPath ${quote(archive)} '
      '-DestinationPath ${quote(p.windows.dirname(executable))} -Force; '
      'Start-Process -FilePath ${quote(executable)}';
}
