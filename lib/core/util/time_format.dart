import 'package:flutter/widgets.dart';

import '../i18n/app_strings.dart';

String _pad2(int value) => value.toString().padLeft(2, '0');

/// Formats an ISO timestamp as a short local `MM/DD HH:mm`, falling back to the
/// localized "unknown" label when the input is missing or unparseable.
String formatShortTime(BuildContext context, String? iso) {
  if (iso == null || iso.isEmpty) return context.l10n.unknown;
  final DateTime? parsed = DateTime.tryParse(iso);
  if (parsed == null) return context.l10n.unknown;
  final DateTime local = parsed.toLocal();
  return '${_pad2(local.month)}/${_pad2(local.day)} '
      '${_pad2(local.hour)}:${_pad2(local.minute)}';
}
