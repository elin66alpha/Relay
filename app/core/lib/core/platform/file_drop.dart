import 'file_drop_stub.dart' show DroppedFile, FileDropController;
import 'file_drop_stub.dart' if (dart.library.html) 'file_drop_web.dart'
    as platform;

export 'file_drop_stub.dart' show DroppedFile, FileDropController;

FileDropController registerFileDrop(
  Future<void> Function(List<DroppedFile> files) onFiles,
) =>
    platform.registerFileDrop(onFiles);
