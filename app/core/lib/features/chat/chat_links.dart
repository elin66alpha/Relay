import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/backend/backend_client.dart';
import '../../core/download/download_manager.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/util/error_text.dart';
import '../filesystem/file_system_screen.dart';

final RegExp _windowsPath = RegExp(r'^([A-Za-z]:[\\/]|\\\\)');
// Agents point at lines as `file.dart#L42`, `file.dart#L4-L9` or `file.dart:42:5`.
final RegExp _lineSuffix = RegExp(r'(#L\d+(-L?\d+)?|:\d+(:\d+)?)$');

/// A Markdown link target from a chat reply: a web address to open in the
/// system browser, or a path on the backend machine. Null means ignore it
/// (anchors, empty targets, and every other scheme, since replies are
/// agent-written and must not trigger arbitrary handlers).
({Uri? web, String? path})? classifyChatLink(String href) {
  final String raw = href.trim();
  if (raw.isEmpty || raw.startsWith('#')) return null;
  String path;
  if (_windowsPath.hasMatch(raw)) {
    path = raw;
  } else {
    final Uri? uri = Uri.tryParse(raw);
    switch (uri?.scheme.toLowerCase()) {
      case 'http':
      case 'https':
        return uri!.host.isEmpty ? null : (web: uri, path: null);
      case 'mailto':
        return (web: uri!, path: null);
      case 'file':
        if (uri!.host.isNotEmpty && uri.host != 'localhost') return null;
        try {
          // The path belongs to the backend; query/line fragments are not filenames.
          path = Uri(path: uri.path).toFilePath(
            windows: RegExp(r'^/[A-Za-z]:').hasMatch(uri.path),
          );
        } on UnsupportedError {
          return null;
        }
      default:
        // `notes.md:42` parses as scheme `notes.md`; any other scheme is refused.
        if (uri != null && uri.hasScheme && !_lineSuffix.hasMatch(raw)) {
          return null;
        }
        try {
          path = Uri.decodeFull(raw);
        } on ArgumentError {
          path = raw;
        }
    }
  }
  path = path.replaceFirst(_lineSuffix, '');
  return path.isEmpty ? null : (web: null, path: path);
}

/// Opens a tapped chat link: web addresses after a confirmation that shows the
/// full address, backend files in the file preview, directories in the browser.
Future<void> openChatLink(
  BuildContext context, {
  required String href,
  required BackendClient backend,
  required String? workdir,
  required Future<WorkdirInfo> Function(String) onSetWorkdir,
}) async {
  final ({Uri? web, String? path})? link = classifyChatLink(href);
  if (link == null) return;
  if (link.web != null) {
    await _openWeb(context, link.web!);
  } else {
    await _openFile(
      context,
      path: link.path!,
      backend: backend,
      workdir: workdir,
      onSetWorkdir: onSetWorkdir,
    );
  }
}

Future<void> _openWeb(BuildContext context, Uri uri) async {
  final AppStrings strings = context.l10n;
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(strings.openLinkTitle),
      content: Text(uri.toString()),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(strings.openLink),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  bool launched;
  try {
    launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    launched = false;
  }
  if (!launched && context.mounted) _notify(context, strings.cannotOpenLink);
}

Future<void> _openFile(
  BuildContext context, {
  required String path,
  required BackendClient backend,
  required String? workdir,
  required Future<WorkdirInfo> Function(String) onSetWorkdir,
}) async {
  final AppStrings strings = context.l10n;
  final bool windows =
      _windowsPath.hasMatch(path) || _windowsPath.hasMatch(workdir ?? '');
  final p.Context paths = p.Context(
    style: windows ? p.Style.windows : p.Style.posix,
  );
  if (!paths.isAbsolute(path) && (workdir == null || workdir.isEmpty)) {
    _notify(context, strings.linkedFileNotFound);
    return;
  }
  final String target = paths.normalize(
    paths.isAbsolute(path) ? path : paths.join(workdir!, path),
  );
  final String parent = paths.dirname(target);
  final NavigatorState navigator = Navigator.of(context);
  if (parent == target) {
    // A filesystem root has no parent listing to look itself up in.
    navigator.push(_browserRoute(backend, onSetWorkdir, target));
    return;
  }
  final String name = paths.basename(target);
  final FsEntry? entry;
  try {
    final FsListing listing = await backend.browseWorkdir(
      parent,
      showHidden: true,
    );
    entry = listing.entries
        .where(
          (FsEntry e) => windows
              ? e.name.toLowerCase() == name.toLowerCase()
              : e.name == name,
        )
        .firstOrNull;
  } catch (err) {
    if (context.mounted) _notify(context, friendlyErrorText(strings, err));
    return;
  }
  if (!context.mounted) return;
  if (entry == null) {
    _notify(context, strings.linkedFileNotFound);
  } else if (entry.isDirectory) {
    navigator.push(_browserRoute(backend, onSetWorkdir, entry.path));
  } else {
    final FsEntry file = entry;
    navigator.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => FilePreviewScreen(
          entry: file,
          open: () => backend.openFileDownload(file.path),
          onDownload: () => DownloadManager.instance.startDownload(
            fileName: file.name,
            strings: strings,
            open: () => backend.openFileDownload(file.path),
          ),
        ),
      ),
    );
  }
}

MaterialPageRoute<void> _browserRoute(
  BackendClient backend,
  Future<WorkdirInfo> Function(String) onSetWorkdir,
  String path,
) {
  return MaterialPageRoute<void>(
    builder: (_) => FileSystemScreen(
      backend: backend,
      onSetWorkdir: onSetWorkdir,
      initialPath: path,
    ),
  );
}

void _notify(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
