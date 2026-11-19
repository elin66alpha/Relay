import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/widgets/author_contact_link.dart';
import 'app_update.dart';
import 'tutorial_screen.dart';
import 'update_check.dart';
import 'wallpaper_screen.dart';

// Shown on the settings screen; keep in step with pubspec.yaml on every release.
const String _applicationVersion = '0.2.1';
const int _fontScaleDivisions = 9;

class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({
    required this.settingsController,
    this.machinesSection,
    super.key,
  });

  final AppSettingsController settingsController;
  // Built by the caller (e.g. from features/chat) so features/settings stays
  // decoupled from features/machines.
  final Widget? machinesSection;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settingsController,
      builder: (BuildContext context, Widget? _) {
        final AppLanguage currentLanguage = settingsController.language;
        final ThemeMode currentThemeMode = settingsController.themeMode;
        final double currentFontScale = settingsController.fontScale;

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
                        if (machinesSection != null) ...<Widget>[
                          _buildSectionTitle(
                            context,
                            context.l10n.credentialTitle,
                          ),
                          Card(
                            margin: const EdgeInsets.only(bottom: 24),
                            clipBehavior: Clip.antiAlias,
                            child: machinesSection,
                          ),
                        ],
                        _buildSectionTitle(context, context.l10n.appearance),
                        Card(
                          margin: const EdgeInsets.only(bottom: 24),
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Align(
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
                                const SizedBox(height: 16),
                                const Divider(height: 1),
                                const SizedBox(height: 16),
                                _buildFontScaleSlider(
                                  context,
                                  currentFontScale,
                                ),
                              ],
                            ),
                          ),
                        ),
                        Card(
                          margin: const EdgeInsets.only(bottom: 24),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            leading: const Icon(Icons.wallpaper_outlined),
                            title: Text(context.l10n.wallpaper),
                            subtitle: Text(context.l10n.wallpaperEntryHint),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) => WallpaperScreen(
                                  settingsController: settingsController,
                                ),
                              ),
                            ),
                          ),
                        ),
                        _buildSectionTitle(context, context.l10n.language),
                        Card(
                          margin: const EdgeInsets.only(bottom: 24),
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
                        _buildSectionTitle(
                          context,
                          context.l10n.notifications,
                        ),
                        Card(
                          margin: const EdgeInsets.only(bottom: 24),
                          child: Column(
                            children: <Widget>[
                              SwitchListTile(
                                title: Text(context.l10n.quotaAlerts),
                                value: settingsController.quotaPushEnabled,
                                onChanged: (bool value) {
                                  settingsController.setQuotaPushEnabled(value);
                                },
                              ),
                              const Divider(
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                              ),
                              SwitchListTile(
                                title: Text(context.l10n.taskAlerts),
                                value: settingsController.taskPushEnabled,
                                onChanged: (bool value) {
                                  settingsController.setTaskPushEnabled(value);
                                },
                              ),
                            ],
                          ),
                        ),
                        _buildSectionTitle(context, context.l10n.tutorial),
                        Card(
                          margin: const EdgeInsets.only(bottom: 24),
                          child: ListTile(
                            leading: const Icon(Icons.school_outlined),
                            title: Text(context.l10n.tutorialHomeTitle),
                            subtitle: Text(context.l10n.tutorialHomeHint),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {
                              Navigator.of(context).push<void>(
                                MaterialPageRoute<void>(
                                  builder: (_) => const TutorialScreen(),
                                ),
                              );
                            },
                          ),
                        ),
                        _buildSectionTitle(context, context.l10n.about),
                        Card(
                          margin: const EdgeInsets.only(bottom: 24),
                          child: Column(
                            children: <Widget>[
                              ListTile(
                                leading: const Icon(Icons.info_outline),
                                title: Text(context.l10n.aboutApp),
                                subtitle: Text(
                                  '${context.l10n.version} '
                                  '$_applicationVersion',
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _showAbout(context),
                              ),
                              const Divider(
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                              ),
                              const _UpdateCheckTile(),
                            ],
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

  Widget _buildFontScaleSlider(BuildContext context, double value) {
    final ThemeData theme = Theme.of(context);
    final int percent = (value * 100).round();
    final bool canReset =
        (value - AppSettingsController.defaultFontScale).abs() > 0.001;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.format_size_outlined),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    context.l10n.fontSize,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${context.l10n.fontSizeDescription} · '
                    '${context.l10n.fontScalePercent(percent)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: context.l10n.resetFontSize,
              onPressed: canReset
                  ? () {
                      settingsController.setFontScale(
                        AppSettingsController.defaultFontScale,
                      );
                    }
                  : null,
              icon: const Icon(Icons.restart_alt),
            ),
          ],
        ),
        Slider(
          value: value,
          min: AppSettingsController.minFontScale,
          max: AppSettingsController.maxFontScale,
          divisions: _fontScaleDivisions,
          label: context.l10n.fontScalePercent(percent),
          onChanged: settingsController.setFontScale,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                context.l10n.fontScalePercent(
                  (AppSettingsController.minFontScale * 100).round(),
                ),
                style: theme.textTheme.labelSmall,
              ),
              Text(
                context.l10n.fontScalePercent(
                  (AppSettingsController.defaultFontScale * 100).round(),
                ),
                style: theme.textTheme.labelSmall,
              ),
              Text(
                context.l10n.fontScalePercent(
                  (AppSettingsController.maxFontScale * 100).round(),
                ),
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ],
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
      applicationVersion: _applicationVersion,
      applicationLegalese: context.l10n.copyright,
      children: <Widget>[
        const SizedBox(height: 8),
        Text(
          context.l10n.aboutDescription,
          style: const TextStyle(height: 1.45),
        ),
        const SizedBox(height: 12),
        Text('${context.l10n.license}: ${context.l10n.licenseText}'),
        const SizedBox(height: 12),
        const AuthorContactLink(textAlign: TextAlign.start),
      ],
    );
  }
}

/// Compares this build with the newest GitHub release. When one is newer and
/// this platform can install it, offers to download and install it; otherwise
/// reports the result. [silent] is the check at app start: it says nothing
/// unless there is an update to install.
Future<void> checkForAppUpdate(
  BuildContext context, {
  bool silent = false,
  String currentVersion = _applicationVersion,
  Future<String> Function() latestVersion = fetchLatestVersion,
}) async {
  final AppStrings strings = context.l10n;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  void report(String message) {
    if (silent) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  final String latest;
  try {
    latest = await latestVersion();
  } catch (_) {
    return report(strings.updateCheckFailed);
  }
  if (!isNewerVersion(latest, currentVersion)) {
    return report(strings.upToDate(currentVersion));
  }
  final String? asset = updateAssetName(latest);
  if (asset == null) {
    // iOS builds are installed and updated through TestFlight.
    return report(
      defaultTargetPlatform == TargetPlatform.iOS
          ? strings.updateInTestFlight(latest)
          : strings.updateAvailable(latest),
    );
  }
  if (!context.mounted) return;
  final bool? install = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(strings.updateAvailableTitle(latest)),
      content: Text(strings.updatePrompt),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(strings.updateLater),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(strings.updateNow),
        ),
      ],
    ),
  );
  if (install != true || !context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) =>
        _UpdateDownloadDialog(version: latest, asset: asset),
  );
}

/// Downloads the update and hands it to the system; closes itself when the
/// system has taken over, and stays open with the error when it fails.
class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({required this.version, required this.asset});

  final String version;
  final String asset;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  double? _progress;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      await downloadAndInstallUpdate(
        widget.version,
        widget.asset,
        onProgress: (double? progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (mounted) Navigator.of(context).pop();
    } catch (err) {
      if (mounted) setState(() => _error = err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = context.l10n;
    final Object? error = _error;
    return AlertDialog(
      title: Text(strings.updateAvailableTitle(widget.version)),
      content: error != null
          ? Text(strings.updateFailed(error))
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _progress == null
                      ? strings.downloadingUpdate
                      : '${strings.downloadingUpdate} '
                          '${(_progress! * 100).round()}%',
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _progress),
              ],
            ),
      actions: <Widget>[
        if (error != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(strings.close),
          ),
      ],
    );
  }
}

class _UpdateCheckTile extends StatefulWidget {
  const _UpdateCheckTile();

  @override
  State<_UpdateCheckTile> createState() => _UpdateCheckTileState();
}

class _UpdateCheckTileState extends State<_UpdateCheckTile> {
  bool _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    await checkForAppUpdate(context);
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.system_update_outlined),
      title: Text(context.l10n.checkForUpdates),
      trailing: _checking
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onTap: _checking ? null : _check,
    );
  }
}
