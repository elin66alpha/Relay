import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/app_strings.dart';

/// Opens a web address in the device's own browser after a confirmation that
/// shows the full address, since the address came from a page or a message.
Future<void> confirmAndOpenWebLink(BuildContext context, Uri uri) async {
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
  if (!launched && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(strings.cannotOpenLink)));
  }
}
