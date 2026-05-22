// ignore_for_file: use_build_context_synchronously

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/backend/backend_client.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/models/machine_credential.dart';
import 'machine_credentials_controller.dart';

class MachineCredentialsScreen extends StatefulWidget {
  const MachineCredentialsScreen({
    required this.machinesController,
    this.requireCredential = false,
    super.key,
  });

  final MachineCredentialsController machinesController;
  final bool requireCredential;

  @override
  State<MachineCredentialsScreen> createState() =>
      _MachineCredentialsScreenState();
}

class _MachineCredentialsScreenState extends State<MachineCredentialsScreen> {
  bool _isImporting = false;
  bool _isTesting = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.machinesController,
      builder: (BuildContext context, Widget? _) {
        final List<MachineCredential> credentials =
            widget.machinesController.credentials;
        final MachineCredential? active =
            widget.machinesController.activeMachine;
        return Scaffold(
          appBar: widget.requireCredential
              ? null
              : AppBar(title: Text(context.l10n.credentialTitle)),
          body: SafeArea(
            child: credentials.isEmpty
                ? _EmptyCredentialState(
                    isImporting: _isImporting,
                    onScan: _scanCredential,
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                        child: Text(
                          context.l10n.currentMachine,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      for (final MachineCredential credential in credentials)
                        _MachineTile(
                          credential: credential,
                          active: credential.id == active?.id,
                          onSelect: () => widget.machinesController.setActive(
                            credential.id,
                          ),
                          onDelete: () => _confirmDelete(credential),
                        ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _isImporting ? null : _scanCredential,
                        icon: _isImporting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.qr_code_scanner_rounded),
                        label: Text(context.l10n.scanQr),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed:
                            active == null || _isTesting ? null : _testActive,
                        icon: _isTesting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.lan_outlined),
                        label: Text(context.l10n.testMachine),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Future<void> _scanCredential() async {
    setState(() => _isImporting = true);
    try {
      final String? raw = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => const _CredentialQrScannerScreen(),
        ),
      );
      if (raw == null || raw.trim().isEmpty) return;
      await _finishImport(Uint8List.fromList(utf8.encode(raw.trim())));
    } catch (err) {
      _showMessage(context.l10n.importFailed(err), error: true);
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _finishImport(Uint8List bytes) async {
    if (!mounted) return;
    final String? passphrase = await _askPassphrase();
    if (passphrase == null) return;

    final MachineCredential credential =
        await widget.machinesController.decryptEncryptedBytes(
      bytes,
      passphrase: passphrase,
    );
    final BackendClient client = BackendClient();
    try {
      final bool ok = await client.healthFor(credential);
      if (!ok) throw BackendException(context.l10n.backendNotOk);
    } finally {
      await client.close();
    }
    await widget.machinesController.saveCredential(credential);
    if (!mounted) return;
    if (!widget.requireCredential) {
      _showMessage(context.l10n.imported(credential.displayName));
    }
  }

  Future<String?> _askPassphrase() async {
    String passphrase = '';
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.l10n.credentialPassword),
        content: TextField(
          obscureText: true,
          autofocus: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: context.l10n.password,
            hintText: context.l10n.passwordHint,
          ),
          onChanged: (String value) => passphrase = value,
          onSubmitted: (_) => Navigator.of(ctx).pop(passphrase.trim()),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(passphrase.trim()),
            child: Text(context.l10n.decrypt),
          ),
        ],
      ),
    );
  }

  Future<void> _testActive() async {
    setState(() => _isTesting = true);
    final BackendClient client = BackendClient();
    try {
      final bool ok = await client.health();
      _showMessage(
        ok ? context.l10n.connectionOk : context.l10n.backendNotOk,
        error: !ok,
      );
    } catch (err) {
      _showMessage(context.l10n.connectionFailed(err), error: true);
    } finally {
      await client.close();
      if (mounted) setState(() => _isTesting = false);
    }
  }

  Future<void> _confirmDelete(MachineCredential credential) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(context.l10n.deleteMachine(credential.displayName)),
        content: Text(context.l10n.deleteMachineBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.machinesController.delete(credential.id);
    }
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}

class _EmptyCredentialState extends StatelessWidget {
  const _EmptyCredentialState({
    required this.isImporting,
    required this.onScan,
  });

  final bool isImporting;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.vpn_key_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 18),
              Text(
                context.l10n.importMachineCredential,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                context.l10n.emptyCredentialText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: isImporting ? null : onScan,
                  icon: isImporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.qr_code_scanner_rounded),
                  label: Text(context.l10n.scanQr),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CredentialQrScannerScreen extends StatefulWidget {
  const _CredentialQrScannerScreen();

  @override
  State<_CredentialQrScannerScreen> createState() =>
      _CredentialQrScannerScreenState();
}

class _CredentialQrScannerScreenState
    extends State<_CredentialQrScannerScreen> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.scanQrTitle)),
      body: Stack(
        children: <Widget>[
          MobileScanner(
            onDetect: (BarcodeCapture capture) {
              if (_handled) return;
              String? value;
              for (final Barcode barcode in capture.barcodes) {
                if (barcode.rawValue != null) {
                  value = barcode.rawValue;
                  break;
                }
              }
              if (value == null || value.trim().isEmpty) return;
              _handled = true;
              Navigator.of(context).pop(value);
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surface
                      .withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(context.l10n.scanQrHint),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MachineTile extends StatelessWidget {
  const _MachineTile({
    required this.credential,
    required this.active,
    required this.onSelect,
    required this.onDelete,
  });

  final MachineCredential credential;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: active ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(
        credential.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        credential.hostLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: context.l10n.delete,
        onPressed: onDelete,
      ),
      selected: active,
      onTap: onSelect,
    );
  }
}
