import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'recorded_audio.dart';

VoiceRecorder createVoiceRecorder() => _WebVoiceRecorder();

class _WebVoiceRecorder implements VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  final List<int> _pcmBytes = <int>[];
  StreamSubscription<Uint8List>? _streamSub;

  static const int _sampleRate = 16000;
  static const int _channels = 1;
  static const int _bitsPerSample = 16;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start() async {
    _pcmBytes.clear();
    await _streamSub?.cancel();
    final Stream<Uint8List> stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: _channels,
      ),
    );
    _streamSub = stream.listen(_pcmBytes.addAll);
  }

  @override
  Future<RecordedAudio?> stop() async {
    await _recorder.stop();
    await _streamSub?.cancel();
    _streamSub = null;
    if (_pcmBytes.isEmpty) return null;
    return RecordedAudio(
      bytes: _wavFromPcm16(Uint8List.fromList(_pcmBytes)),
      mimeType: 'audio/wav',
    );
  }

  @override
  Future<void> dispose() async {
    await _streamSub?.cancel();
    await _recorder.dispose();
  }

  Uint8List _wavFromPcm16(Uint8List pcm) {
    const int headerSize = 44;
    const int byteRate = _sampleRate * _channels * (_bitsPerSample ~/ 8);
    const int blockAlign = _channels * (_bitsPerSample ~/ 8);
    final ByteData header = ByteData(headerSize);

    void writeString(int offset, String value) {
      for (int i = 0; i < value.length; i++) {
        header.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeString(0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
    writeString(8, 'WAVE');
    writeString(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, _channels, Endian.little);
    header.setUint32(24, _sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, _bitsPerSample, Endian.little);
    writeString(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);

    final Uint8List wav = Uint8List(headerSize + pcm.length);
    wav.setRange(0, headerSize, header.buffer.asUint8List());
    wav.setRange(headerSize, wav.length, pcm);
    return wav;
  }
}
