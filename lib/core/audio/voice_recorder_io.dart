import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'recorded_audio.dart';

VoiceRecorder createVoiceRecorder() => _IoVoiceRecorder();

class _IoVoiceRecorder implements VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  String? _recordingPath;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start() async {
    final Directory tempDir = await getTemporaryDirectory();
    final String path =
        '${tempDir.path}/agentdeck-voice-${DateTime.now().microsecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 16000,
      ),
      path: path,
    );
    _recordingPath = path;
  }

  @override
  Future<RecordedAudio?> stop() async {
    final String? path = await _recorder.stop() ?? _recordingPath;
    _recordingPath = null;
    if (path == null || path.isEmpty) return null;
    final File file = File(path);
    try {
      return RecordedAudio(
        bytes: await file.readAsBytes(),
        mimeType: _mimeTypeFor(path),
      );
    } finally {
      await _deleteRecording(file);
    }
  }

  @override
  Future<void> dispose() => _recorder.dispose();

  Future<void> _deleteRecording(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Best effort cleanup.
    }
  }

  String _mimeTypeFor(String path) {
    final String lower = path.toLowerCase();
    if (lower.endsWith('.m4a') || lower.endsWith('.mp4')) return 'audio/mp4';
    if (lower.endsWith('.wav')) return 'audio/wav';
    if (lower.endsWith('.webm')) return 'audio/webm';
    return 'application/octet-stream';
  }
}
