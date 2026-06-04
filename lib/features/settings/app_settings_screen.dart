import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/settings/app_settings_controller.dart';

class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({
    required this.settingsController,
    super.key,
  });

  final AppSettingsController settingsController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settingsController,
      builder: (BuildContext context, Widget? _) {
        final AppLanguage currentLanguage = settingsController.language;
        final ThemeMode currentThemeMode = settingsController.themeMode;

        return Scaffold(
          appBar: AppBar(
            title: Text(context.l10n.settings),
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              children: <Widget>[
                Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _buildSectionTitle(context, context.l10n.appearance),
                        Card(
                          elevation: 0,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerLow,
                          margin: const EdgeInsets.only(bottom: 24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: SegmentedButton<ThemeMode>(
                                  segments: <ButtonSegment<ThemeMode>>[
                                    ButtonSegment<ThemeMode>(
                                      value: ThemeMode.system,
                                      icon: const Icon(
                                        Icons.settings_suggest_outlined,
                                      ),
                                      label: Text(context.l10n.systemTheme),
                                    ),
                                    ButtonSegment<ThemeMode>(
                                      value: ThemeMode.light,
                                      icon: const Icon(
                                        Icons.light_mode_outlined,
                                      ),
                                      label: Text(context.l10n.lightTheme),
                                    ),
                                    ButtonSegment<ThemeMode>(
                                      value: ThemeMode.dark,
                                      icon: const Icon(
                                        Icons.dark_mode_outlined,
                                      ),
                                      label: Text(context.l10n.darkTheme),
                                    ),
                                  ],
                                  selected: <ThemeMode>{currentThemeMode},
                                  onSelectionChanged:
                                      (Set<ThemeMode> selected) {
                                    settingsController
                                        .setThemeMode(selected.first);
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                        _buildSectionTitle(context, context.l10n.language),
                        Card(
                          elevation: 0,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerLow,
                          margin: const EdgeInsets.only(bottom: 24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: SegmentedButton<AppLanguage>(
                                  segments: <ButtonSegment<AppLanguage>>[
                                    ButtonSegment<AppLanguage>(
                                      value: AppLanguage.en,
                                      label: Text(context.l10n.english),
                                    ),
                                    ButtonSegment<AppLanguage>(
                                      value: AppLanguage.zh,
                                      label: Text(context.l10n.chinese),
                                    ),
                                  ],
                                  selected: <AppLanguage>{currentLanguage},
                                  onSelectionChanged:
                                      (Set<AppLanguage> selected) {
                                    settingsController
                                        .setLanguage(selected.first);
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                        _buildSectionTitle(context, context.l10n.about),
                        Card(
                          elevation: 0,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerLow,
                          margin: const EdgeInsets.only(bottom: 24),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ListTile(
                            leading: const Icon(Icons.info_outline),
                            title: Text(context.l10n.aboutApp),
                            subtitle:
                                Text('${context.l10n.version} 0.1.0+1'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _showAbout(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        title,
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontSize: 13,
          fontWeight: FontWeight.bold,
          letterSpacing: 0,
        ),
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: context.l10n.appName,
      applicationVersion: '0.1.0+1',
      applicationLegalese: context.l10n.copyright,
      children: <Widget>[
        const SizedBox(height: 8),
        Text(
          context.l10n.aboutDescription,
          style: const TextStyle(height: 1.45),
        ),
        const SizedBox(height: 12),
        Text('${context.l10n.license}: ${context.l10n.licenseText}'),
      ],
    );
  }
}
