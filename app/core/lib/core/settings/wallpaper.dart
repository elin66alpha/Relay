import 'dart:typed_data';

class Wallpaper {
  const Wallpaper({
    this.bytes,
    this.lightOpacity = 0.8,
    this.darkOpacity = 0.2,
    this.blur = defaultBlur,
    this.tint = defaultTint,
  });

  static const double defaultBlur = 6;
  static const double maxBlur = 30;
  static const double defaultTint = 0.55;

  final Uint8List? bytes;
  final double lightOpacity;
  final double darkOpacity;

  /// Blur sigma of the acrylic surfaces over the image, shared by both themes.
  final double blur;

  /// Opacity of the theme colour each acrylic surface lays over its blur.
  final double tint;

  Wallpaper withImage(Uint8List? value) => Wallpaper(
        bytes: value,
        lightOpacity: lightOpacity,
        darkOpacity: darkOpacity,
        blur: blur,
        tint: tint,
      );

  Wallpaper withOpacity({required bool dark, required double value}) =>
      Wallpaper(
        bytes: bytes,
        lightOpacity: dark ? lightOpacity : value,
        darkOpacity: dark ? value : darkOpacity,
        blur: blur,
        tint: tint,
      );

  Wallpaper withAcrylic({double? blur, double? tint}) => Wallpaper(
        bytes: bytes,
        lightOpacity: lightOpacity,
        darkOpacity: darkOpacity,
        blur: blur ?? this.blur,
        tint: tint ?? this.tint,
      );
}
