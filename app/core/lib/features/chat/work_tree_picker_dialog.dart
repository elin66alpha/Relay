import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';

/// A minimal directory navigator over `/api/workdir/browse` for choosing a
/// swarm's work tree. Returns the selected directory's absolute path, or null on
/// cancel. Lists directories only (files can't be a work tree).
class WorkTreePickerDialog extends StatefulWidget {
  const WorkTreePickerDialog({
    super.key,
    required this.backend,
    required this.start,
  });

  final BackendClient backend;
  final String start;

  @override
  State<WorkTreePickerDialog> createState() => _WorkTreePickerDialogState();
}

class _WorkTreePickerDialogState extends State<WorkTreePickerDialog> {
  FsListing? _listing;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load(widget.start);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final FsListing listing = await widget.backend.browseWorkdir(path);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } on BackendException catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final FsListing? listing = _listing;
    final List<FsEntry> dirs = listing == null
        ? const <FsEntry>[]
        : listing.entries.where((FsEntry e) => e.isDirectory).toList();
    return AlertDialog(
      title: Text(strings.swarmChooseWorkTree),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: <Widget>[
            if (listing != null)
              Row(
                children: <Widget>[
                  IconButton(
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: listing.parentPath == null
                        ? null
                        : () => _load(listing.parentPath!),
                  ),
                  Expanded(
                    child: Text(
                      listing.absolutePath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text(_error!))
                      : ListView(
                          children: <Widget>[
                            for (final FsEntry dir in dirs)
                              ListTile(
                                dense: true,
                                leading: const Icon(Icons.folder_outlined),
                                title: Text(dir.name),
                                onTap: () => _load(dir.absolutePath),
                              ),
                          ],
                        ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed: listing == null
              ? null
              : () => Navigator.of(context).pop(listing.absolutePath),
          child: Text(strings.ok),
        ),
      ],
    );
  }
}
