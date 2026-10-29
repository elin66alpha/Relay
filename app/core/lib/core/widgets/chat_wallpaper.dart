import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../i18n/app_strings.dart';
import '../platform/wallpaper_processor_common.dart';
import '../settings/wallpaper.dart';

class WallpaperScope extends InheritedWidget {
  const WallpaperScope({
    required this.enabled,
    required super.child,
    this.blur = Wallpaper.defaultBlur,
    this.tint = Wallpaper.defaultTint,
    super.key,
  });

  final bool enabled;
  final double blur;
  final double tint;

  static WallpaperScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WallpaperScope>();

  static bool enabledOf(BuildContext context) => of(context)?.enabled ?? false;

  @override
  bool updateShouldNotify(WallpaperScope oldWidget) =>
      enabled != oldWidget.enabled ||
      blur != oldWidget.blur ||
      tint != oldWidget.tint;
}

/// A single centered image spans the transcript and its surrounding chrome.
///
/// Every acrylic surface in [child] blurs from one shared backdrop snapshot,
/// rather than copying the screen once per surface. That is exact as long as
/// sibling surfaces never overlap; a surface that covers other content, such
/// as a drawer, wraps itself in its own [BackdropGroup].
class ChatWallpaper extends StatelessWidget {
  const ChatWallpaper({
    required this.wallpaper,
    required this.child,
    this.opacity,
    this.blurred = false,
    super.key,
  });

  final Wallpaper wallpaper;
  final Widget child;
  final Animation<double>? opacity;

  /// Blurs the image itself, for a page that shows it through one full-page
  /// tint: the image is all that is behind, so no backdrop needs reading.
  final bool blurred;

  static final Expando<img.DecodeInfo> _sizes = Expando<img.DecodeInfo>();

  /// Decodes only as many pixels as the display can show: a full-size camera
  /// photo costs hundreds of MB of texture that every frame samples. The square
  /// box keeps the short side at the display's long side, so the image still
  /// covers the screen in either orientation; the stored file stays original.
  static ImageProvider _provider(BuildContext context, Uint8List bytes) {
    final MemoryImage image = MemoryImage(bytes);
    final img.DecodeInfo info;
    try {
      info = _sizes[bytes] ??= wallpaperInfo(bytes);
    } on FormatException {
      return image;
    }
    final Size display = View.of(context).display.size;
    final double scale = math.max(display.width, display.height) /
        math.min(info.width, info.height);
    if (scale >= 1) return image;
    final int box = (math.max(info.width, info.height) * scale).ceil();
    return ResizeImage(
      image,
      width: box,
      height: box,
      policy: ResizeImagePolicy.fit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget image = wallpaper.bytes == null
        ? const SizedBox.expand()
        : Image(
            image: _provider(context, wallpaper.bytes!),
            fit: BoxFit.cover,
            alignment: Alignment.center,
            gaplessPlayback: true,
            opacity: opacity ??
                AlwaysStoppedAnimation<double>(
                  theme.brightness == Brightness.dark
                      ? wallpaper.darkOpacity
                      : wallpaper.lightOpacity,
                ),
            errorBuilder: (_, __, ___) => const SizedBox.expand(),
          );
    return WallpaperScope(
      enabled: wallpaper.bytes != null,
      blur: wallpaper.blur,
      tint: wallpaper.tint,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(
            child: RepaintBoundary(
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: theme.scaffoldBackgroundColor,
                    child: blurred
                        ? ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: 20,
                              sigmaY: 20,
                              tileMode: TileMode.clamp,
                            ),
                            child: image,
                          )
                        : image,
                  ),
                ),
              ),
            ),
          ),
          ScrollConfiguration(
            behavior: wallpaper.bytes == null
                ? ScrollConfiguration.of(context)
                : const _GlowScrollBehavior(),
            child: BackdropGroup(child: child),
          ),
        ],
      ),
    );
  }
}

/// Android's stretch overscroll renders the list into an offscreen layer,
/// where acrylic surfaces have no wallpaper to blur; the glow paints in place.
class _GlowScrollBehavior extends MaterialScrollBehavior {
  const _GlowScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (getPlatform(context) != TargetPlatform.android) {
      return super.buildOverscrollIndicator(context, child, details);
    }
    return GlowingOverscrollIndicator(
      axisDirection: details.direction,
      color: Theme.of(context).colorScheme.secondary,
      child: child,
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
    final WallpaperScope? scope = acrylic ? WallpaperScope.of(context) : null;
    final Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: acrylic
            ? color.withValues(alpha: scope?.tint ?? Wallpaper.defaultTint)
            : color,
        border: border,
        borderRadius: borderRadius,
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
    if (!acrylic) return surface;
    final double sigma = scope?.blur ?? Wallpaper.defaultBlur;
    final ImageFilter blur = ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    // A nested surface must blur this one too, so it starts a fresh group.
    final Widget layered = BackdropGroup(child: surface);
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropGroup.of(context) == null
          ? BackdropFilter(filter: blur, child: layered)
          : BackdropFilter.grouped(filter: blur, child: layered),
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
                  blurred: true,
                  child: ColoredBox(
                    color: theme.scaffoldBackgroundColor.withValues(
                      alpha: 0.72,
                    ),
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
