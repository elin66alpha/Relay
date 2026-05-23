import 'dart:typed_data';

class RecordedAudio {
  const RecordedAudio({
    required this.bytes,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String mimeType;
}

abstract class VoiceRecorder {
  Future<bool> hasPermission();
  Future<void> start();
  Future<RecordedAudio?> stop();
  Future<void> dispose();
}
