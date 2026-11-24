import 'dart:convert';
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
    await startWindowsReplace(
      pid: pid,
      archive: file.path,
      executable: Platform.resolvedExecutable,
    );
    exit(0);
  }
  final OpenResult result = await OpenFilex.open(file.path);
  if (result.type != ResultType.done) {
    throw FileSystemException(result.message, file.path);
  }
}

/// Starts the PowerShell that replaces the app ([windowsReplaceScript]) in a
/// process that outlives the app. Windows PowerShell silently does nothing
/// without a console, and Dart's detached mode starts programs without one,
/// so `cmd start` gives it a console of its own, minimised and then hidden.
/// The script and its log go next to [archive].
Future<void> startWindowsReplace({
  required int pid,
  required String archive,
  required String executable,
}) async {
  final String dir = p.windows.dirname(archive);
  final File script = File(p.windows.join(dir, 'relay-client-update.ps1'));
  // The BOM makes Windows PowerShell read the script as UTF-8 rather than in
  // the ANSI code page, which would garble non-ASCII user and folder names.
  await script.writeAsString(
    '﻿${windowsReplaceScript(
      pid: pid,
      archive: archive,
      executable: executable,
      log: p.windows.join(dir, 'relay-client-update.log'),
    )}',
    encoding: utf8,
  );
  await Process.start(
    'cmd.exe',
    windowsReplaceCommand(script.path),
    mode: ProcessStartMode.detached,
  );
}

/// `cmd.exe` arguments that run [script] in a new, hidden PowerShell window.
List<String> windowsReplaceCommand(String script) => <String>[
      '/c',
      'start',
      '/min',
      'powershell.exe',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      script,
    ];

/// The Windows release is a ZIP of the app folder, and a running program's
/// files cannot be replaced. This PowerShell waits for the app to exit,
/// unpacks the ZIP over the folder the app runs from (retrying while another
/// program, such as a virus scanner, still holds a file), deletes the ZIP and
/// starts the app again. The app restarts even when unpacking keeps failing;
/// each failure is appended to [log].
String windowsReplaceScript({
  required int pid,
  required String archive,
  required String executable,
  required String log,
}) {
  String quote(String value) => "'${value.replaceAll("'", "''")}'";
  final String from = quote(archive);
  return <String>[
    r"$ProgressPreference = 'SilentlyContinue'",
    // An app started from PowerShell 7 passes on its PSModulePath, whose
    // Archive module fails under Windows PowerShell.
    r'Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Archive"',
    'Wait-Process -Id $pid -ErrorAction SilentlyContinue',
    r'for ($attempt = 1; $attempt -le 5; $attempt++) {',
    '  try {',
    '    Expand-Archive -LiteralPath $from '
        '-DestinationPath ${quote(p.windows.dirname(executable))} '
        '-Force -ErrorAction Stop',
    '    Remove-Item -LiteralPath $from -ErrorAction SilentlyContinue',
    '    break',
    '  } catch {',
    r'    "$(Get-Date -Format o) attempt ${attempt}: $_" |',
    '      Out-File -LiteralPath ${quote(log)} -Append -Encoding utf8',
    '    Start-Sleep -Seconds 2',
    '  }',
    '}',
    'Start-Process -FilePath ${quote(executable)}',
    '',
  ].join('\r\n');
}
