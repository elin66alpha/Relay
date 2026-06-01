import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

String decodeCredentialQrImage(Uint8List bytes) {
  final img.Image? image = img.decodeImage(bytes);
  if (image == null) {
    throw const FormatException('Unable to decode image.');
  }
  final img.Image scanImage = _resizeForScanning(image);
  final img.Image rgba = scanImage.convert(numChannels: 4);
  final LuminanceSource source = RGBLuminanceSource(
    rgba.width,
    rgba.height,
    rgba.getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List(),
  );
  final BinaryBitmap bitmap = BinaryBitmap(HybridBinarizer(source));
  try {
    return QRCodeReader().decode(bitmap).text;
  } catch (_) {
    throw const FormatException('Unable to find a QR code in the image.');
  }
}

img.Image _resizeForScanning(img.Image image) {
  const int maxSide = 768;
  final int longestSide =
      image.width > image.height ? image.width : image.height;
  if (longestSide <= maxSide) return image;
  final double scale = maxSide / longestSide;
  return img.copyResize(
    image,
    width: (image.width * scale).round(),
    height: (image.height * scale).round(),
    interpolation: img.Interpolation.nearest,
  );
}
