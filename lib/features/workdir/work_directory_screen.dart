// ignore_for_file: use_build_context_synchronously

import 'package:flutter/material.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../chat/bot_chat_controller.dart';

class WorkDirectoryScreen extends StatefulWidget {
  const WorkDirectoryScreen({
    required this.chatController,
    super.key,
  });

  final BotChatController chatController;

  @override
  State<WorkDirectoryScreen> createState() => _WorkDirectoryScreenState();
}

class _WorkDirectoryScreenState extends State<WorkDirectoryScreen> {
  final TextEditingController _path = TextEditingController();
  bool _isLoading = true;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final WorkdirInfo info = await widget.chatController.workdir();
      if (!mounted) return;
      setState(() {
        _path.text = info.dir;
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

  bool _looksAbsolute(String value) {
    final String text = value.trim();
    return text.startsWith('/') ||
        text == '~' ||
        text.startsWith('~/') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(text);
  }

  Future<void> _save({bool create = false}) async {
    final String value = _path.text.trim();
    if (!_looksAbsolute(value)) {
      setState(() => _error = context.l10n.workdirMustBeAbsolute);
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      final WorkdirInfo info =
          await widget.chatController.setWorkdir(value, create: create);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.workdirUpdated)),
      );
      Navigator.of(context).pop(info.dir);
    } catch (err) {
      if (!mounted) return;
      if (err is BackendException && err.code == 'WORKDIR_NOT_FOUND') {
        setState(() => _isSaving = false);
        final bool? ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: Text(context.l10n.pathMissingTitle),
            content: Text(context.l10n.pathMissingBody(value)),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(context.l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(context.l10n.create),
              ),
            ],
          ),
        );
        if (ok == true) await _save(create: true);
        return;
      }
      setState(() {
        _error = err is BackendException && err.code == 'WORKDIR_BUSY'
            ? context.l10n.workdirBusy
            : err.toString();
        _isSaving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.workDirectory)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    controller: _path,
                    enabled: !_isLoading && !_isSaving,
                    decoration: InputDecoration(
                      labelText: context.l10n.workDirectory,
                      hintText: context.l10n.workDirectoryHint,
                      border: const OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _isSaving ? null : _save(),
                  ),
                  const SizedBox(height: 12),
                  if (_isLoading)
                    Text(context.l10n.loadingWorkDirectory)
                  else if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _isLoading || _isSaving ? null : _save,
                    child: Text(context.l10n.save),
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
