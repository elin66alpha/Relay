// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/download/download_manager.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/platform/file_drop.dart';
import '../../core/util/error_text.dart';
import '../../core/util/format_bytes.dart';
import '../../core/util/time_format.dart';
import '../../core/widgets/code_block.dart';

/// Unified file browser: browse the whole filesystem (up to root), set the work
/// path from here, upload into the current folder, and download files/folders to
/// the system Downloads folder. Download progress lives in [DownloadManager] so
/// it survives leaving and re-entering this screen.
class FileSystemScreen extends StatefulWidget {
  const FileSystemScreen({
    required this.backend,
    required this.onSetWorkdir,
    super.key,
  });

  final BackendClient backend;
  final Future<WorkdirInfo> Function(String) onSetWorkdir;

  @override
  State<FileSystemScreen> createState() => _FileSystemScreenState();
}

class _FileSystemScreenState extends State<FileSystemScreen> {
  static const int _maxUploadBytes = 100 * 1024 * 1024;

  final DownloadManager _downloads = DownloadManager.instance;

  FsListing? _listing;
  FileDropController? _dropController;
  bool _isLoading = true;
  bool _isBusy = false;
  bool _showHidden = false;
  String? _error;
  String? _operationText;
  String? _workPath;
  late int _seenDownloadTick;
  bool _downloadActive = false;

  @override
  void initState() {
    super.initState();
    _seenDownloadTick = _downloads.completedTick;
    _downloadActive = _downloads.isActive;
    _downloads.addListener(_onDownloadChanged);
    _dropController = registerFileDrop(_uploadDroppedFiles);
    _loadInitial();
  }

  @override
  void dispose() {
    _downloads.removeListener(_onDownloadChanged);
    _dropController?.dispose();
    super.dispose();
  }

  void _onDownloadChanged() {
    if (!mounted) return;
    // Show a one-shot snackbar when a download settles while we're on screen.
    if (_downloads.completedTick != _seenDownloadTick) {
      _seenDownloadTick = _downloads.completedTick;
      final String? message = _downloads.stage == DownloadStage.done
          ? _downloads.savedLocation
          : _downloads.errorText;
      if (message != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    }
    // Progress ticks repaint only the status widget (via the ListenableBuilder in
    // build); rebuild the whole screen only when the active state flips, to
    // enable/disable the per-row download buttons.
    if (_downloads.isActive != _downloadActive) {
      setState(() => _downloadActive = _downloads.isActive);
    }
  }

  Future<void> _loadInitial() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final WorkdirInfo info = await widget.backend.workdir();
      if (!mounted) return;
      _workPath = info.dir;
      await _browse(info.dir);
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = friendlyErrorText(context.l10n, err);
        _isLoading = false;
      });
    }
  }

  Future<void> _browse(String path) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final FsListing listing = await widget.backend.browseWorkdir(
        path,
        showHidden: _showHidden,
      );
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _isLoading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = friendlyErrorText(context.l10n, err);
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleHiddenFiles() async {
    final String path = _listing?.absolutePath ?? _workPath ?? '';
    setState(() => _showHidden = !_showHidden);
    if (path.isNotEmpty) await _browse(path);
  }

  Future<void> _setAsWorkPath() async {
    final FsListing? listing = _listing;
    if (listing == null) return;
    final String target = listing.absolutePath;
    if (_workPath == target) return;
    final String? previous = _workPath;
    // Update the label immediately and keep the browser fully usable. The backend
    // sync (events reconnect + conversation reload, which fetches history over the
    // slow tunnel) runs in the background instead of freezing the file list.
    setState(() {
      _error = null;
      _workPath = target;
    });
    try {
      final WorkdirInfo info = await widget.onSetWorkdir(target);
      if (!mounted) return;
      setState(() => _workPath = info.dir);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.workdirUpdated)),
      );
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _workPath = previous; // revert the optimistic update on failure
        _error = err is BackendException && err.code == 'WORKDIR_BUSY'
            ? context.l10n.workdirBusy
            : friendlyErrorText(context.l10n, err);
      });
    }
  }

  Future<void> _createFolder() async {
    final FsListing? listing = _listing;
    if (listing == null || _isLoading || _isBusy) return;
    final AppStrings strings = context.l10n;
    String draftName = '';
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(strings.newFolder),
          content: TextFormField(
            autofocus: true,
            decoration: InputDecoration(labelText: strings.folderName),
            textInputAction: TextInputAction.done,
            onChanged: (String value) => draftName = value,
            onFieldSubmitted: (String value) =>
                Navigator.of(dialogContext).pop(value.trim()),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(strings.cancel),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(draftName.trim()),
              child: Text(strings.create),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty || !mounted) return;
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      final FsEntry created = await widget.backend.createDirectory(
        path: listing.absolutePath,
        name: name,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.folderCreated(created.name))),
      );
      await _browse(listing.absolutePath);
    } catch (err) {
      if (!mounted) return;
      setState(
        () => _error = context.l10n.createFolderFailed(
          friendlyErrorText(context.l10n, err),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _pickUpload() async {
    final FilePickerResult? result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: kIsWeb,
      withReadStream: !kIsWeb,
    );
    if (result == null) return;
    final List<_UploadFile> files = <_UploadFile>[];
    for (final PlatformFile file in result.files) {
      if (kIsWeb) {
        final Uint8List? bytes = file.bytes;
        if (bytes == null) continue;
        files.add(_UploadFile.bytes(name: file.name, data: bytes));
      } else {
        final Stream<List<int>>? bytes = file.readStream;
        if (bytes == null) continue;
        files.add(
          _UploadFile.stream(
            name: file.name,
            data: bytes,
            length: file.size,
          ),
        );
      }
    }
    await _uploadFiles(files);
  }

  Future<void> _uploadDroppedFiles(List<DroppedFile> dropped) {
    return _uploadFiles(
      dropped
          .map(
            (DroppedFile file) => _UploadFile.bytes(
              name: file.name,
              data: file.bytes,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<void> _uploadFiles(List<_UploadFile> files) async {
    final FsListing? listing = _listing;
    if (listing == null || files.isEmpty || _isBusy) return;
    // Reject oversized files up front so we never push them over the tunnel; the
    // backend enforces the same cap as a safety net.
    final List<_UploadFile> tooBig =
        files.where((_UploadFile f) => f.length > _maxUploadBytes).toList();
    final List<_UploadFile> toUpload =
        files.where((_UploadFile f) => f.length <= _maxUploadBytes).toList();
    if (tooBig.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(context.l10n.uploadTooLarge(tooBig.first.name, '100 MB')),
        ),
      );
    }
    if (toUpload.isEmpty) return;
    setState(() {
      _isBusy = true;
      _operationText = context.l10n.uploadingFile(toUpload.first.name);
      _error = null;
    });
    try {
      int uploaded = 0;
      for (final _UploadFile file in toUpload) {
        if (!mounted) return;
        setState(() => _operationText = context.l10n.uploadingFile(file.name));
        final Uint8List? bytes = file.bytes;
        if (bytes != null) {
          await widget.backend.uploadFile(
            path: listing.absolutePath,
            name: file.name,
            bytes: bytes,
          );
        } else {
          await widget.backend.uploadFileStream(
            path: listing.absolutePath,
            name: file.name,
            bytes: file.readStream!,
            length: file.length,
          );
        }
        uploaded += 1;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.uploadComplete(uploaded))),
      );
      await _browse(listing.absolutePath);
    } catch (err) {
      if (!mounted) return;
      setState(
        () => _error = context.l10n.uploadFailed(
          friendlyErrorText(context.l10n, err),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _operationText = null;
        });
      }
    }
  }

  void _download(FsEntry entry) {
    if (_downloads.isActive) return;
    // Fire-and-forget: the manager owns the lifecycle, so the transfer and its
    // completion notification continue even if this screen is popped.
    _downloads.startDownload(
      fileName: entry.name,
      strings: context.l10n,
      open: () => widget.backend.openFileDownload(entry.path),
    );
  }

  void _open(FsEntry entry) {
    if (entry.isDirectory) {
      _browse(entry.path);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => _FilePreviewScreen(
          entry: entry,
          open: () => widget.backend.openFileDownload(entry.path),
          onDownload: () => _download(entry),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FsListing? listing = _listing;
    final bool atWorkPath = listing != null &&
        _workPath != null &&
        listing.absolutePath == _workPath;
    final String activePath = listing?.absolutePath ?? _workPath ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.fileSystem),
        actions: <Widget>[
          IconButton(
            tooltip: _showHidden
                ? context.l10n.hideHiddenFiles
                : context.l10n.showHiddenFiles,
            onPressed: _isLoading || _isBusy ? null : _toggleHiddenFiles,
            icon: Icon(
              _showHidden
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
          ),
          IconButton(
            tooltip: context.l10n.refresh,
            onPressed: _isLoading || _isBusy
                ? null
                : activePath.isEmpty
                    ? _loadInitial
                    : () => _browse(activePath),
            icon: const Icon(Icons.refresh_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1040),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _BreadcrumbBar(
                        path: activePath,
                        canGoUp: listing?.parentPath != null,
                        atWorkPath: atWorkPath,
                        busy: _isLoading || _isBusy,
                        onParent: listing?.parentPath == null
                            ? null
                            : () => _browse(listing!.parentPath!),
                        onNavigate: _browse,
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          FilledButton.icon(
                            onPressed: _isLoading || _isBusy || atWorkPath
                                ? null
                                : _setAsWorkPath,
                            icon: Icon(
                              atWorkPath
                                  ? Icons.check_rounded
                                  : Icons.flag_outlined,
                            ),
                            label: Text(context.l10n.setAsWorkPath),
                          ),
                          OutlinedButton.icon(
                            onPressed: _isLoading || _isBusy || listing == null
                                ? null
                                : _createFolder,
                            icon: const Icon(Icons.create_new_folder_outlined),
                            label: Text(context.l10n.newFolder),
                          ),
                          OutlinedButton.icon(
                            onPressed:
                                _isLoading || _isBusy ? null : _pickUpload,
                            icon: const Icon(Icons.upload_file_outlined),
                            label: Text(context.l10n.uploadFile),
                          ),
                          if (_workPath != null && !atWorkPath)
                            ActionChip(
                              avatar: Icon(
                                Icons.folder_open_rounded,
                                size: 16,
                                color: theme.colorScheme.primary,
                              ),
                              label: Text(
                                context.l10n.currentWorkPath(_workPath!),
                                overflow: TextOverflow.ellipsis,
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: _isLoading || _isBusy
                                  ? null
                                  : () => _browse(_workPath!),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        kIsWeb
                            ? '${context.l10n.transferLimitHint} ${context.l10n.dragDropUpload}'
                            : context.l10n.transferLimitHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      ListenableBuilder(
                        listenable: _downloads,
                        builder: (BuildContext context, Widget? _) =>
                            _DownloadStatus(downloads: _downloads),
                      ),
                      if (_operationText != null) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(_operationText!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: _isLoading
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(context.l10n.loadingFiles),
                      ],
                    )
                  : _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(16),
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1040),
                              child: SizedBox(
                                width: double.infinity,
                                child: Text(
                                  _error!,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      : listing == null
                          ? const SizedBox.shrink()
                          : CustomScrollView(
                              slivers: <Widget>[
                                SliverPadding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    4,
                                    16,
                                    16,
                                  ),
                                  sliver: _FileList(
                                    listing: listing,
                                    workPath: _workPath,
                                    isBusy: _isBusy,
                                    downloadActive: _downloadActive,
                                    onOpen: _open,
                                    onDownload: _download,
                                    onParent: listing.parentPath == null ||
                                            _isBusy
                                        ? null
                                        : () => _browse(listing.parentPath!),
                                  ),
                                ),
                              ],
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Splits an absolute POSIX or Windows path into `(label, path)` breadcrumb
/// segments from root down to the target directory.
List<({String label, String path})> splitPathBreadcrumbs(String rawPath) {
  final String trimmed = rawPath.trim();
  if (trimmed.isEmpty) return const <({String label, String path})>[];
  if (trimmed.startsWith('/')) {
    final List<({String label, String path})> crumbs =
        <({String label, String path})>[(label: '/', path: '/')];
    String current = '';
    for (final String part in trimmed.split('/')) {
      if (part.isEmpty) continue;
      current = '$current/$part';
      crumbs.add((label: part, path: current));
    }
    return crumbs;
  }
  final String sep = trimmed.contains(r'\') ? r'\' : '/';
  final List<String> parts = trimmed
      .split(RegExp(r'[\\/]+'))
      .where((String part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) {
    return <({String label, String path})>[(label: trimmed, path: trimmed)];
  }
  final bool isUnc = trimmed.startsWith(r'\\') && parts.length >= 2;
  final String rootName =
      isUnc ? '$sep$sep${parts[0]}$sep${parts[1]}' : parts.first;
  final String root = '$rootName$sep';
  final List<({String label, String path})> crumbs =
      <({String label, String path})>[(label: rootName, path: root)];
  String current = rootName;
  for (int i = isUnc ? 2 : 1; i < parts.length; i += 1) {
    current = '$current$sep${parts[i]}';
    crumbs.add((label: parts[i], path: current));
  }
  return crumbs;
}

class _BreadcrumbBar extends StatelessWidget {
  const _BreadcrumbBar({
    required this.path,
    required this.canGoUp,
    required this.atWorkPath,
    required this.busy,
    required this.onParent,
    required this.onNavigate,
  });

  final String path;
  final bool canGoUp;
  final bool atWorkPath;
  final bool busy;
  final VoidCallback? onParent;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<({String label, String path})> crumbs =
        splitPathBreadcrumbs(path);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: <Widget>[
            IconButton(
              tooltip: context.l10n.parentFolder,
              visualDensity: VisualDensity.compact,
              onPressed: busy || !canGoUp ? null : onParent,
              icon: const Icon(Icons.arrow_upward_outlined, size: 20),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (int i = 0; i < crumbs.length; i += 1) ...<Widget>[
                        if (i > 0)
                          Icon(
                            Icons.chevron_right,
                            size: 16,
                            color: theme.colorScheme.outline,
                          ),
                        _BreadcrumbChip(
                          label: crumbs[i].label,
                          current: i == crumbs.length - 1,
                          onTap: busy || !canGoUp || i == crumbs.length - 1
                              ? null
                              : () => onNavigate(crumbs[i].path),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (atWorkPath)
              Padding(
                padding: const EdgeInsets.only(left: 6, right: 6),
                child: Chip(
                  label: Text(context.l10n.workPathTag),
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BreadcrumbChip extends StatelessWidget {
  const _BreadcrumbChip({
    required this.label,
    required this.current,
    this.onTap,
  });

  final String label;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget text = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Text(
        label,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: current ? FontWeight.w600 : FontWeight.w400,
          color: current
              ? theme.colorScheme.onSurface
              : onTap != null
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    if (onTap == null) return text;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: text,
    );
  }
}

String? _decodePreview((Uint8List, bool) input) {
  final (Uint8List bytes, bool truncated) = input;
  if (bytes.contains(0)) return null;
  int end = bytes.length;
  if (truncated) {
    // The size cap can split the last UTF-8 character; drop it.
    int lead = end - 1;
    while (lead > end - 4 && lead > 0 && (bytes[lead] & 0xC0) == 0x80) {
      lead--;
    }
    if (bytes[lead] >= 0xC0) end = lead;
  }
  try {
    return utf8.decode(Uint8List.sublistView(bytes, 0, end));
  } on FormatException {
    return null;
  }
}

class _FilePreviewScreen extends StatefulWidget {
  const _FilePreviewScreen({
    required this.entry,
    required this.open,
    required this.onDownload,
  });

  final FsEntry entry;
  final Future<FsDownloadStream> Function() open;
  final VoidCallback onDownload;

  @override
  State<_FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<_FilePreviewScreen> {
  static const int _maxPreviewBytes = 512 * 1024;

  final DownloadManager _downloads = DownloadManager.instance;
  StreamIterator<List<int>>? _chunks;
  bool _isLoading = true;
  bool _truncated = false;
  String? _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _chunks?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final FsDownloadStream download = await widget.open();
      final StreamIterator<List<int>> chunks = StreamIterator(download.bytes);
      if (!mounted) {
        await chunks.cancel();
        return;
      }
      _chunks = chunks;
      final BytesBuilder bytes = BytesBuilder(copy: false);
      bool truncated = false;
      try {
        while (bytes.length < _maxPreviewBytes && await chunks.moveNext()) {
          final List<int> chunk = chunks.current;
          final int remaining = _maxPreviewBytes - bytes.length;
          if (chunk.length > remaining) {
            bytes.add(chunk.sublist(0, remaining));
            truncated = true;
          } else {
            bytes.add(chunk);
          }
        }
      } finally {
        await chunks.cancel();
      }
      if (!mounted) return;
      truncated = truncated ||
          (bytes.length == _maxPreviewBytes &&
              (download.total ?? widget.entry.size) > _maxPreviewBytes);
      final String? text = await compute(
        _decodePreview,
        (bytes.takeBytes(), truncated),
      );
      if (!mounted) return;
      setState(() {
        _text = text;
        _truncated = truncated;
        _isLoading = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = friendlyErrorText(context.l10n, err);
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String name = widget.entry.name.toLowerCase();
    final String? language = name == 'dockerfile' || name == 'makefile'
        ? name
        : name.contains('.')
            ? name.substring(name.lastIndexOf('.') + 1)
            : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.name),
        actions: <Widget>[
          ListenableBuilder(
            listenable: _downloads,
            builder: (BuildContext context, Widget? _) => IconButton(
              tooltip: context.l10n.download,
              onPressed: _downloads.isActive ? null : widget.onDownload,
              icon: const Icon(Icons.download_outlined),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_truncated) Text(context.l10n.filePreviewTruncated),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null || _text == null
                        ? Center(
                            child: Text(
                              _error ?? context.l10n.cannotPreviewFile,
                            ),
                          )
                        : SelectionArea(
                            child: SingleChildScrollView(
                              child: CodeBlock(
                                code: _text!,
                                color: theme.colorScheme.onSurface,
                                language: language,
                              ),
                            ),
                          ),
              ),
              ListenableBuilder(
                listenable: _downloads,
                builder: (BuildContext context, Widget? _) =>
                    _DownloadStatus(downloads: _downloads),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders the current [DownloadManager] state inline: a live progress bar while
/// downloading, or the saved location / error once it settles.
class _DownloadStatus extends StatelessWidget {
  const _DownloadStatus({required this.downloads});

  final DownloadManager downloads;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    switch (downloads.stage) {
      case DownloadStage.downloading:
      case DownloadStage.saving:
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: _DownloadProgress(
            name: downloads.fileName ?? '',
            received: downloads.received,
            total: downloads.total,
            saving: downloads.stage == DownloadStage.saving,
          ),
        );
      case DownloadStage.done:
        final String text =
            downloads.savedLocation ?? context.l10n.downloadComplete;
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.check_circle_outline,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(text, style: theme.textTheme.bodySmall),
              ),
            ],
          ),
        );
      case DownloadStage.failed:
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            downloads.errorText ?? '',
            style: TextStyle(color: theme.colorScheme.error),
          ),
        );
      case DownloadStage.idle:
        return const SizedBox.shrink();
    }
  }
}

class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({
    required this.name,
    required this.received,
    required this.total,
    required this.saving,
  });

  final String name;
  final int received;
  final int? total;
  final bool saving;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasTotal = total != null && total! > 0;
    // While saving to disk the byte stream is done; show a full, indeterminate bar.
    final double? value =
        saving ? null : (hasTotal ? (received / total!).clamp(0.0, 1.0) : null);
    final int percent = hasTotal ? ((received / total!) * 100).round() : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          hasTotal && !saving
              ? context.l10n.downloadProgress(name, percent)
              : context.l10n.downloadIndeterminate(name),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: value, minHeight: 6),
        ),
        if (hasTotal && !saving) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            '${formatBytes(received)} / ${formatBytes(total!)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ],
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({
    required this.listing,
    required this.workPath,
    required this.isBusy,
    required this.downloadActive,
    required this.onOpen,
    required this.onDownload,
    required this.onParent,
  });

  final FsListing listing;
  final String? workPath;
  final bool isBusy;
  final bool downloadActive;
  final ValueChanged<FsEntry> onOpen;
  final ValueChanged<FsEntry> onDownload;
  final VoidCallback? onParent;

  // Swiping right over the list goes up one folder, like the parent button.
  Widget _swipeToParent(Widget child) {
    return GestureDetector(
      onHorizontalDragEnd: onParent == null
          ? null
          : (DragEndDetails details) {
              if ((details.primaryVelocity ?? 0) > 300) onParent!();
            },
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool hasParent = listing.parentPath != null;
    final int parentCount = hasParent ? 1 : 0;
    final int bodyCount = listing.entries.isEmpty ? 1 : listing.entries.length;
    final int totalCount = parentCount + bodyCount;
    final ColorScheme colors = Theme.of(context).colorScheme;

    return SliverList.builder(
      itemCount: totalCount,
      itemBuilder: (BuildContext context, int index) {
        final Widget tile;
        if (hasParent && index == 0) {
          tile = ListTile(
            leading: const Icon(Icons.drive_folder_upload_outlined),
            title: const Text('..'),
            subtitle: Text(context.l10n.parentFolder),
            enabled: !isBusy,
            onTap: isBusy ? null : onParent,
          );
        } else if (listing.entries.isEmpty) {
          tile = ListTile(title: Text(context.l10n.emptyFolder));
        } else {
          final FsEntry entry = listing.entries[index - parentCount];
          final bool isWorkPath =
              entry.isDirectory && entry.absolutePath == workPath;
          tile = ListTile(
            leading: Icon(
              entry.isDirectory
                  ? (isWorkPath
                      ? Icons.folder_open_rounded
                      : Icons.folder_outlined)
                  : Icons.insert_drive_file_outlined,
              color: isWorkPath ? colors.primary : null,
            ),
            title: Text(entry.name),
            subtitle: Text(_subtitleFor(context, entry, isWorkPath)),
            enabled: !isBusy,
            onTap: (entry.isDirectory || entry.isFile) && !isBusy
                ? () => onOpen(entry)
                : null,
            trailing: IconButton(
              tooltip: context.l10n.download,
              onPressed:
                  isBusy || downloadActive ? null : () => onDownload(entry),
              icon: const Icon(Icons.download_outlined),
            ),
          );
        }
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: _swipeToParent(
              _FileListFrame(
                first: index == 0,
                last: index == totalCount - 1,
                child: tile,
              ),
            ),
          ),
        );
      },
    );
  }

  String _subtitleFor(BuildContext context, FsEntry entry, bool isWorkPath) {
    final String type = entry.isDirectory
        ? context.l10n.fileTypeDirectory
        : entry.isFile
            ? context.l10n.fileTypeFile
            : context.l10n.fileTypeOther;
    final String workTag = isWorkPath ? ' · ${context.l10n.workPathTag}' : '';
    final String size =
        entry.isDirectory ? '' : ' · ${formatBytes(entry.size)}';
    final String modifiedAt = formatLongTime(entry.modifiedAt);
    final String modified = modifiedAt.isEmpty ? '' : ' · $modifiedAt';
    return '$type$workTag$size$modified';
  }
}

class _FileListFrame extends StatelessWidget {
  const _FileListFrame({
    required this.first,
    required this.last,
    required this.child,
  });

  final bool first;
  final bool last;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.outlineVariant;
    const Radius radius = Radius.circular(8);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: first ? BorderSide(color: color) : BorderSide.none,
          left: BorderSide(color: color),
          right: BorderSide(color: color),
          bottom: BorderSide(color: color),
        ),
        borderRadius: BorderRadius.vertical(
          top: first ? radius : Radius.zero,
          bottom: last ? radius : Radius.zero,
        ),
      ),
      child: child,
    );
  }
}

class _UploadFile {
  const _UploadFile.bytes({
    required this.name,
    required Uint8List data,
  })  : bytes = data,
        readStream = null,
        length = data.length;

  const _UploadFile.stream({
    required this.name,
    required Stream<List<int>> data,
    required this.length,
  })  : bytes = null,
        readStream = data;

  final String name;
  final Uint8List? bytes;
  final Stream<List<int>>? readStream;
  final int length;
}
