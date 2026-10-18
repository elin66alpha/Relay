import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/platform/wallpaper_processor.dart';
import '../../core/settings/wallpaper.dart';
import '../../core/settings/app_settings_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/chat_wallpaper.dart';

class WallpaperScreen extends StatefulWidget {
  const WallpaperScreen({required this.settingsController, super.key});

  final AppSettingsController settingsController;

  @override
  State<WallpaperScreen> createState() => _WallpaperScreenState();
}

class _WallpaperScreenState extends State<WallpaperScreen>
    with SingleTickerProviderStateMixin {
  late Wallpaper _draft;
  late final AnimationController _opacity;
  final ValueNotifier<bool> _dirty = ValueNotifier<bool>(false);
  bool? _dark;
  bool _loadingImage = false;
  bool _saving = false;
  String? _error;
  bool get _busy => _loadingImage || _saving;

  @override
  void initState() {
    super.initState();
    _draft = widget.settingsController.wallpaper;
    _opacity = AnimationController(vsync: this, value: _draft.lightOpacity);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    if (_dark != dark) {
      _dark = dark;
      _opacity.value = dark ? _draft.darkOpacity : _draft.lightOpacity;
    }
  }

  @override
  void dispose() {
    _opacity.dispose();
    _dirty.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    try {
      await widget.settingsController.saveWallpaper(_draft);
      if (!mounted) return;
      _dirty.value = false;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.wallpaperSaved)));
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.wallpaperSaveError);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _chooseImage() async {
    setState(() {
      _loadingImage = true;
      _error = null;
    });
    try {
      final FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['jpg', 'jpeg', 'png', 'webp'],
        withData: false,
        withReadStream: true,
      );
      if (result == null || !mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final PlatformFile file = result.files.single;
      const int? limit = wallpaperImportLimit;
      if (file.size <= 0 ||
          (limit != null && file.size > limit) ||
          file.readStream == null) {
        throw const FormatException('wallpaper size');
      }
      final BytesBuilder bytes = BytesBuilder(copy: false);
      await for (final List<int> chunk in file.readStream!) {
        if (!mounted) return;
        if (limit != null && bytes.length + chunk.length > limit) {
          throw const FormatException('wallpaper size');
        }
        bytes.add(chunk);
      }
      final Uint8List image = await prepareWallpaper(bytes.takeBytes());
      if (!mounted) return;
      setState(
        () => _draft = Wallpaper(
          bytes: image,
          lightOpacity: _draft.lightOpacity,
          darkOpacity: _draft.darkOpacity,
        ),
      );
      _dirty.value = true;
    } on FormatException {
      if (mounted) setState(() => _error = context.l10n.wallpaperImportError);
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.wallpaperSaveError);
    } finally {
      if (mounted) setState(() => _loadingImage = false);
    }
  }

  void _removeImage() {
    setState(() {
      _error = null;
      _draft = Wallpaper(
        lightOpacity: _draft.lightOpacity,
        darkOpacity: _draft.darkOpacity,
      );
    });
    _dirty.value = true;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppStrings strings = context.l10n;
    final bool hasImage = _draft.bytes != null;
    final String mode = _dark! ? strings.darkTheme : strings.lightTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.wallpaper),
        actions: <Widget>[
          if (_loadingImage)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: strings.wallpaperProcessing,
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: SizedBox(
              width: double.infinity,
              child: ValueListenableBuilder<bool>(
                valueListenable: _dirty,
                builder: (BuildContext context, bool dirty, Widget? _) =>
                    FilledButton.icon(
                  onPressed: dirty && !_busy ? _save : null,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(strings.save),
                ),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    strings.wallpaperDescription,
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    strings.wallpaperPreview,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Stack(
                    children: <Widget>[
                      _WallpaperPreview(wallpaper: _draft, opacity: _opacity),
                      if (_loadingImage)
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface
                                  .withValues(alpha: 0.8),
                              borderRadius:
                                  BorderRadius.circular(AppTheme.panelRadius),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(strings.wallpaperProcessing),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    hasImage ? strings.wallpaperFit : strings.noWallpaper,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: _busy ? null : _chooseImage,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: Text(
                          hasImage
                              ? strings.replaceWallpaper
                              : strings.chooseWallpaper,
                        ),
                      ),
                      if (hasImage)
                        TextButton.icon(
                          onPressed: _busy ? null : _removeImage,
                          icon: const Icon(Icons.delete_outline),
                          label: Text(strings.removeWallpaper),
                        ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    strings.wallpaperFileHint,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    strings.wallpaperOpacity,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    strings.wallpaperOpacityHint,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  AnimatedBuilder(
                    animation: _opacity,
                    builder: (BuildContext context, Widget? _) {
                      final String percent =
                          '${(_opacity.value * 100).round()}%';
                      return Column(
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(
                                _dark!
                                    ? Icons.dark_mode_outlined
                                    : Icons.light_mode_outlined,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Expanded(child: Text(mode)),
                              Text(percent, style: theme.textTheme.labelLarge),
                            ],
                          ),
                          Slider(
                            key: const ValueKey<String>('wallpaper-opacity'),
                            value: _opacity.value,
                            label: percent,
                            semanticFormatterCallback: (double value) =>
                                '$mode ${(value * 100).round()}%',
                            onChanged: !hasImage || _busy
                                ? null
                                : (double value) {
                                    _opacity.value = value;
                                    _draft = _draft.withOpacity(
                                      dark: _dark!,
                                      value: value,
                                    );
                                    _dirty.value = true;
                                  },
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WallpaperPreview extends StatelessWidget {
  const _WallpaperPreview({required this.wallpaper, required this.opacity});
  final Wallpaper wallpaper;
  final Animation<double> opacity;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final bool acrylic = wallpaper.bytes != null;
    final BorderSide edge = BorderSide(color: colors.outlineVariant);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.panelRadius),
        border: Border.all(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 280,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) =>
              ChatWallpaper(
            wallpaper: wallpaper,
            opacity: opacity,
            child: Row(
              children: <Widget>[
                if (constraints.maxWidth >= 520)
                  ChatChromeSurface(
                    acrylic: acrylic,
                    color: colors.surfaceContainer,
                    border: Border(right: edge),
                    child: SizedBox(
                      width: 156,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Relay',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 24),
                            const Icon(Icons.chat_bubble_outline),
                            const SizedBox(height: 10),
                            Text(context.l10n.wallpaperPreview),
                          ],
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(
                    children: <Widget>[
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Align(
                                alignment: Alignment.centerRight,
                                child: ChatChromeSurface(
                                  acrylic: acrylic,
                                  color: colors.primaryContainer,
                                  border:
                                      Border.all(color: colors.outlineVariant),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    child: Text(
                                      context.l10n.wallpaperPreviewPrompt,
                                      style: TextStyle(
                                        color: colors.onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              ChatChromeSurface(
                                acrylic: acrylic,
                                color: colors.surfaceContainerLow,
                                border:
                                    Border.all(color: colors.outlineVariant),
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child:
                                      Text(context.l10n.wallpaperPreviewText),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      ChatChromeSurface(
                        acrylic: acrylic,
                        color: colors.surfaceContainer,
                        border: Border(top: edge),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: colors.surface.withValues(
                                      alpha: acrylic ? 0.18 : 1,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  child: Text(
                                    context.l10n.inputHint,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Icon(
                                Icons.arrow_upward_rounded,
                                color: colors.primary,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
