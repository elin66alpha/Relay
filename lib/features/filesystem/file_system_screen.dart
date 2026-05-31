// ignore_for_file: use_build_context_synchronously

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/platform/file_drop.dart';
import '../../core/platform/file_saver.dart';
import '../chat/bot_chat_controller.dart';

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
  FsListing? _listing;
  FileDropController? _dropController;
  bool _isLoading = true;
  bool _isBusy = false;
  bool _showHidden = false;
  String? _error;
  String? _operationText;

  @override
  void initState() {
    super.initState();
    _dropController = registerFileDrop(_uploadDroppedFiles);
    _load('');
  }

  @override
  void dispose() {
    _dropController?.dispose();
    super.dispose();
  }

  Future<void> _load(String path) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final FsListing listing = await widget.chatController.listFiles(
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
    final String path = _listing?.path ?? '';
    setState(() => _showHidden = !_showHidden);
    await _load(path);
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
    setState(() {
      _isBusy = true;
      _operationText = context.l10n.uploadingFile(files.first.name);
      _error = null;
    });
    try {
      int uploaded = 0;
      for (final _UploadFile file in files) {
        if (!mounted) return;
        setState(() => _operationText = context.l10n.uploadingFile(file.name));
        await widget.chatController.uploadFile(
          path: listing.path,
          name: file.name,
          bytes: file.bytes,
        );
        uploaded += 1;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.uploadComplete(uploaded))),
      );
      await _load(listing.path);
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

  Future<void> _download(FsEntry entry) async {
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      _operationText = context.l10n.downloadingFile(entry.name);
      _error = null;
    });
    try {
      final FsDownload download =
          await widget.chatController.downloadFile(entry.path);
      await saveDownloadedFile(
        fileName: download.fileName,
        bytes: download.bytes,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.downloadStarted(download.fileName)),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = context.l10n.downloadFailed(err));
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _operationText = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.fileSystem)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed:
                            _isLoading || _isBusy ? null : () => _pickUpload(),
                        icon: const Icon(Icons.upload_file_outlined),
                        label: Text(context.l10n.uploadFile),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isLoading || _isBusy
                            ? null
                            : () => _load(_listing?.path ?? ''),
                        icon: const Icon(Icons.refresh_outlined),
                        label: Text(context.l10n.refresh),
                      ),
                    ],
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
                            Expanded(child: Text(context.l10n.dragDropUpload)),
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
                  if (_listing != null)
                    SelectableText(
                      _listing!.absolutePath,
                      style: theme.textTheme.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      OutlinedButton.icon(
                        onPressed: _listing?.parentPath == null ||
                                _isLoading ||
                                _isBusy
                            ? null
                            : () => _load(_listing!.parentPath!),
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
                  ] else if (_listing != null) ...<Widget>[
                    const SizedBox(height: 12),
                    _FileList(
                      listing: _listing!,
                      isBusy: _isBusy,
                      onOpen: (FsEntry entry) => _load(entry.path),
                      onDownload: _download,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({
    required this.listing,
    required this.isBusy,
    required this.onOpen,
    required this.onDownload,
  });

  final FsListing listing;
  final bool isBusy;
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
                onPressed: isBusy ? null : () => onDownload(entry),
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
    final String modified = entry.modifiedAt.isEmpty
        ? ''
        : ' · ${entry.modifiedAt.replaceFirst('T', ' ').split('.').first}';
    return '$type$size$modified';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final double kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final double mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }
}

class _UploadFile {
  const _UploadFile({
    required this.name,
    required this.bytes,
  });

  final String name;
  final Uint8List bytes;
}
