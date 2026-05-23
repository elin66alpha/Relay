import 'recorded_audio.dart';
import 'voice_recorder_stub.dart'
    if (dart.library.io) 'voice_recorder_io.dart'
    if (dart.library.html) 'voice_recorder_web.dart' as platform;

export 'recorded_audio.dart';

VoiceRecorder createVoiceRecorder() => platform.createVoiceRecorder();
