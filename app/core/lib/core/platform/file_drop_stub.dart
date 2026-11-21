import 'dart:typed_data';

class DroppedFile {
  const DroppedFile({
    required this.name,
    required this.size,
    required this.readBytes,
  });

  final String name;
  final int size;

  /// Read only for accepted files, so dropping a huge one loads nothing.
  final Future<Uint8List> Function() readBytes;
}

abstract class FileDropController {
  void dispose();
}

class NoopFileDropController implements FileDropController {
  const NoopFileDropController();

  @override
  void dispose() {}
}

FileDropController registerFileDrop(
  Future<void> Function(List<DroppedFile> files) onFiles,
) =>
    const NoopFileDropController();
