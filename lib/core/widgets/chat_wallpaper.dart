import 'dart:ui';

import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../settings/wallpaper.dart';

class WallpaperScope extends InheritedWidget {
  const WallpaperScope({
    required this.enabled,
    required super.child,
    super.key,
  });

  final bool enabled;

  static bool enabledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WallpaperScope>()?.enabled ??
      false;

  @override
  bool updateShouldNotify(WallpaperScope oldWidget) =>
      enabled != oldWidget.enabled;
}

/// A single centered image spans the transcript and its surrounding chrome.
class ChatWallpaper extends StatelessWidget {
  const ChatWallpaper({
    required this.wallpaper,
    required this.child,
    this.opacity,
    super.key,
  });

  final Wallpaper wallpaper;
  final Widget child;
  final Animation<double>? opacity;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return WallpaperScope(
      enabled: wallpaper.bytes != null,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(
            child: RepaintBoundary(
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: theme.scaffoldBackgroundColor,
                    child: wallpaper.bytes == null
                        ? const SizedBox.expand()
                        : Image.memory(
                            wallpaper.bytes!,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            gaplessPlayback: true,
                            opacity: opacity ??
                                AlwaysStoppedAnimation<double>(
                                  theme.brightness == Brightness.dark
                                      ? wallpaper.darkOpacity
                                      : wallpaper.lightOpacity,
                                ),
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.expand(),
                          ),
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Blur stays clipped to the panel; a hairline defines its edge over any image.
class ChatChromeSurface extends StatelessWidget {
  const ChatChromeSurface({
    required this.acrylic,
    required this.color,
    required this.border,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    super.key,
  });

  final bool acrylic;
  final Color color;
  final Border border;
  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: acrylic ? color.withValues(alpha: 0.72) : color,
        border: border,
        borderRadius: borderRadius,
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
    if (!acrylic) return surface;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: surface,
      ),
    );
  }
}

/// An AppBar `flexibleSpace` over a wallpaper, reaching under the status bar.
class AcrylicAppBarBackground extends StatelessWidget {
  const AcrylicAppBarBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ChatChromeSurface(
      acrylic: true,
      color: colors.surface,
      border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      child: const SizedBox.expand(),
    );
  }
}

/// A pushed page shows the wallpaper through one full-page acrylic layer.
class WallpaperBackdrop extends StatelessWidget {
  const WallpaperBackdrop({
    required this.child,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final Wallpaper wallpaper = context.appSettings.wallpaper;
    final bool on = enabled && wallpaper.bytes != null;
    final ThemeData theme = Theme.of(context);
    // The tree keeps one shape so saving a wallpaper never remounts the page.
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          child: on
              ? ChatWallpaper(
                  wallpaper: wallpaper,
                  child: ChatChromeSurface(
                    acrylic: true,
                    color: theme.scaffoldBackgroundColor,
                    border: const Border(),
                    child: const SizedBox.expand(),
                  ),
                )
              : const SizedBox.shrink(),
        ),
        Theme(
          data: on
              ? theme.copyWith(
                  scaffoldBackgroundColor: Colors.transparent,
                  appBarTheme: theme.appBarTheme.copyWith(
                    backgroundColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                  ),
                )
              : theme,
          child: child,
        ),
      ],
    );
  }
}
