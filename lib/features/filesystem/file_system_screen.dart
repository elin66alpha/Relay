// ignore_for_file: use_build_context_synchronously

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/download/download_manager.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/platform/file_drop.dart';
import '../chat/bot_chat_controller.dart';

/// Unified file browser: browse the whole filesystem (up to root), set the work
/// path from here, upload into the current folder, and download files/folders to
/// the system Downloads folder. Download progress lives in [DownloadManager] so
/// it survives leaving and re-entering this screen.
class FileSystemScreen extends StatefulWidget {
  const FileSystemScreen({
    required this.chatController,
    super.key,
  });

  final BotChatController chatController;

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
      final WorkdirInfo info = await widget.chatController.workdir();
      _workPath = info.dir;
      await _browse(info.dir);
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err.toString();
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
      final FsListing listing = await widget.chatController.browseWorkdir(
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
        _error = err.toString();
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
      final WorkdirInfo info = await widget.chatController.setWorkdir(target);
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
            : err.toString();
      });
    }
  }

  Future<void> _pickUpload() async {
    final FilePickerResult? result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    final List<_UploadFile> files = <_UploadFile>[];
    for (final PlatformFile file in result.files) {
      final Uint8List? bytes = file.bytes;
      if (bytes == null) continue;
      files.add(_UploadFile(name: file.name, bytes: bytes));
    }
    await _uploadFiles(files);
  }

  Future<void> _uploadDroppedFiles(List<DroppedFile> dropped) {
    return _uploadFiles(
      dropped
          .map(
            (DroppedFile file) => _UploadFile(
              name: file.name,
              bytes: file.bytes,
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
        files.where((_UploadFile f) => f.bytes.length > _maxUploadBytes).toList();
    final List<_UploadFile> toUpload =
        files.where((_UploadFile f) => f.bytes.length <= _maxUploadBytes).toList();
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
        await widget.chatController.uploadFile(
          path: listing.absolutePath,
          name: file.name,
          bytes: file.bytes,
        );
        uploaded += 1;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.uploadComplete(uploaded))),
      );
      await _browse(listing.absolutePath);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = context.l10n.uploadFailed(err));
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
      open: () => widget.chatController.openFileDownload(entry.path),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FsListing? listing = _listing;
    final bool atWorkPath = listing != null &&
        _workPath != null &&
        listing.absolutePath == _workPath;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.fileSystem)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (_workPath != null)
                      Text(
                        context.l10n.currentWorkPath(_workPath!),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton.icon(
                          onPressed: _isLoading || _isBusy
                              ? null
                              : () => _pickUpload(),
                          icon: const Icon(Icons.upload_file_outlined),
                          label: Text(context.l10n.uploadFile),
                        ),
                        OutlinedButton.icon(
                          onPressed: _isLoading || _isBusy || atWorkPath
                              ? null
                              : _setAsWorkPath,
                          icon: const Icon(Icons.flag_outlined),
                          label: Text(context.l10n.setAsWorkPath),
                        ),
                        OutlinedButton.icon(
                          onPressed: _isLoading || _isBusy
                              ? null
                              : () => _browse(
                                    _listing?.absolutePath ?? _workPath ?? '',
                                  ),
                          icon: const Icon(Icons.refresh_outlined),
                          label: Text(context.l10n.refresh),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.transferLimitHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    if (kIsWeb) ...<Widget>[
                      const SizedBox(height: 12),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: <Widget>[
                              const Icon(Icons.drive_folder_upload_outlined),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(context.l10n.dragDropUpload),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Text(
                      context.l10n.currentFolder,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    if (listing != null)
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: SelectableText(
                              listing.absolutePath,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          if (atWorkPath)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Chip(
                                label: Text(context.l10n.workPathTag),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        OutlinedButton.icon(
                          onPressed: listing?.parentPath == null ||
                                  _isLoading ||
                                  _isBusy
                              ? null
                              : () => _browse(listing!.parentPath!),
                          icon: const Icon(Icons.arrow_upward_outlined),
                          label: Text(context.l10n.parentFolder),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              _isLoading || _isBusy ? null : _toggleHiddenFiles,
                          icon: Icon(
                            _showHidden
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                          label: Text(
                            _showHidden
                                ? context.l10n.hideHiddenFiles
                                : context.l10n.showHiddenFiles,
                          ),
                        ),
                      ],
                    ),
                    ListenableBuilder(
                      listenable: _downloads,
                      builder: (BuildContext context, Widget? _) =>
                          _DownloadStatus(downloads: _downloads),
                    ),
                    if (_operationText != null) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(_operationText!),
                    ],
                    if (_isLoading) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(context.l10n.loadingFiles),
                    ] else if (_error != null) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ] else if (listing != null) ...<Widget>[
                      const SizedBox(height: 12),
                      _FileList(
                        listing: listing,
                        isBusy: _isBusy,
                        downloadActive: _downloadActive,
                        onOpen: (FsEntry entry) => _browse(entry.path),
                        onDownload: _download,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
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
            '${_formatBytes(received)} / ${_formatBytes(total!)}',
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
    required this.isBusy,
    required this.downloadActive,
    required this.onOpen,
    required this.onDownload,
  });

  final FsListing listing;
  final bool isBusy;
  final bool downloadActive;
  final ValueChanged<FsEntry> onOpen;
  final ValueChanged<FsEntry> onDownload;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: <Widget>[
          if (listing.entries.isEmpty)
            ListTile(title: Text(context.l10n.emptyFolder)),
          for (final FsEntry entry in listing.entries)
            ListTile(
              leading: Icon(
                entry.isDirectory
                    ? Icons.folder_outlined
                    : Icons.insert_drive_file_outlined,
              ),
              title: Text(entry.name),
              subtitle: Text(_subtitleFor(context, entry)),
              enabled: !isBusy,
              onTap: entry.isDirectory && !isBusy ? () => onOpen(entry) : null,
              trailing: IconButton(
                tooltip: context.l10n.download,
                onPressed:
                    isBusy || downloadActive ? null : () => onDownload(entry),
                icon: const Icon(Icons.download_outlined),
              ),
            ),
        ],
      ),
    );
  }

  String _subtitleFor(BuildContext context, FsEntry entry) {
    final String type = entry.isDirectory
        ? context.l10n.fileTypeDirectory
        : entry.isFile
            ? context.l10n.fileTypeFile
            : context.l10n.fileTypeOther;
    final String size =
        entry.isDirectory ? '' : ' · ${_formatBytes(entry.size)}';
    final String modifiedAt = _formatModifiedAt(entry.modifiedAt);
    final String modified = modifiedAt.isEmpty ? '' : ' · $modifiedAt';
    return '$type$size$modified';
  }

  String _formatModifiedAt(String iso) {
    if (iso.isEmpty) return '';
    final DateTime? parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso.replaceFirst('T', ' ').split('.').first;
    final DateTime local = parsed.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final double kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final double mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

class _UploadFile {
  const _UploadFile({
    required this.name,
    required this.bytes,
  });

  final String name;
  final Uint8List bytes;
}
