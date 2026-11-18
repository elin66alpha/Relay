import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/app_strings.dart';

final Uri authorGitHubUri = Uri.parse('https://github.com/elin66alpha');

Future<void> openAuthorGitHub(BuildContext context) async {
  final AppStrings strings = context.l10n;
  bool launched;
  try {
    launched = await launchUrl(
      authorGitHubUri,
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    launched = false;
  }
  if (!launched && context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(strings.cannotOpenLink)));
  }
}

class AuthorContactLink extends StatelessWidget {
  const AuthorContactLink({this.textAlign = TextAlign.center, super.key});

  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Semantics(
      link: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => openAuthorGitHub(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(
            context.l10n.contactAuthorOnGitHub,
            textAlign: textAlign,
            style: TextStyle(
              color: colors.primary,
              decoration: TextDecoration.underline,
              decorationColor: colors.primary,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}
