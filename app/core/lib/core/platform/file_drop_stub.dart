import 'dart:typed_data';

class DroppedFile {
  const DroppedFile({
    required this.name,
    required this.bytes,
  });

  final String name;
  final Uint8List bytes;
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
