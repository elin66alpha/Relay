import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Replaces the platform file picker for a widget test. Each pick returns
/// what [onPick] produces; [restore] puts the real picker back.
final class FakeFilePicker extends FilePickerPlatform {
  FakeFilePicker(this.onPick);

  final FutureOr<List<PlatformFile>> Function(FileType type) onPick;
  final List<FileType> calls = <FileType>[];
  late final FilePickerPlatform _previous;

  static FakeFilePicker install(
    FutureOr<List<PlatformFile>> Function(FileType type) onPick,
  ) {
    final FakeFilePicker fake = FakeFilePicker(onPick);
    fake._previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = fake;
    return fake;
  }

  void restore() => FilePickerPlatform.instance = _previous;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls.add(type);
    return onPick(type);
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls.add(type);
    final List<PlatformFile> files = await onPick(type);
    return files.isEmpty ? null : files.first;
  }
}

/// An in-memory picked file.
final class FakePickedFile extends PlatformFile {
  FakePickedFile(this.name, this.bytes);

  @override
  final String name;
  final Uint8List bytes;

  @override
  Uri get uri => Uri.file('/picked/$name');

  @override
  get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => bytes.length;

  @override
  Future<int?> length() async => bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream<Uint8List>.value(bytes);
}
