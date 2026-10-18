import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Accepts only a JPEG, PNG or WebP image with real dimensions.
img.DecodeInfo wallpaperInfo(Uint8List bytes) {
  final img.Decoder? decoder =
      bytes.isEmpty ? null : img.findDecoderForData(bytes);
  if (decoder == null ||
      !<img.ImageFormat>[
        img.ImageFormat.jpg,
        img.ImageFormat.png,
        img.ImageFormat.webp,
      ].contains(decoder.format)) {
    throw const FormatException('wallpaper format');
  }
  final img.DecodeInfo? info = decoder.startDecode(bytes);
  if (info == null || info.width <= 0 || info.height <= 0) {
    throw const FormatException('wallpaper image');
  }
  return info;
}
