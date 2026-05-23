import 'recorded_audio.dart';

VoiceRecorder createVoiceRecorder() => _UnsupportedVoiceRecorder();

class _UnsupportedVoiceRecorder implements VoiceRecorder {
  @override
  Future<bool> hasPermission() async => false;

  @override
  Future<void> start() async {
    throw UnsupportedError(
      'Voice recording is not supported on this platform.',
    );
  }

  @override
  Future<RecordedAudio?> stop() async => null;

  @override
  Future<void> dispose() async {}
}
