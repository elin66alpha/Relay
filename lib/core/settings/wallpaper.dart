import 'dart:typed_data';

class Wallpaper {
  const Wallpaper({
    this.bytes,
    this.lightOpacity = 0.8,
    this.darkOpacity = 0.2,
  });

  final Uint8List? bytes;
  final double lightOpacity;
  final double darkOpacity;

  Wallpaper withOpacity({required bool dark, required double value}) =>
      Wallpaper(
        bytes: bytes,
        lightOpacity: dark ? lightOpacity : value,
        darkOpacity: dark ? value : darkOpacity,
      );
}
