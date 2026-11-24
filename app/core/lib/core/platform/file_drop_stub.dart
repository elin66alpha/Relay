import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'platform_capabilities.dart';

const MethodChannel fileDropChannel = MethodChannel('dev.relay.app/file_drop');

class DroppedFile {
  const DroppedFile({
    required this.name,
    required this.size,
    required this.readBytes,
    this.openStream,
  });

  final String name;
  final int size;

  /// Read only for accepted files, so dropping a huge one loads nothing.
  final Future<Uint8List> Function() readBytes;

  /// Native desktop drops stream directly from disk when available.
  final Stream<List<int>> Function()? openStream;
}

abstract class FileDropController {
  void dispose();
}

class NoopFileDropController implements FileDropController {
  const NoopFileDropController();

  @override
  void dispose() {}
}

class NativeFileDropController implements FileDropController {
  NativeFileDropController(this._onFiles, {ValueChanged<bool>? onHoverChanged})
      : _onHoverChanged = onHoverChanged {
    _attach(this);
  }

  static final List<NativeFileDropController> _controllers =
      <NativeFileDropController>[];
  static bool _handlerRegistered = false;

  final Future<void> Function(List<DroppedFile> files) _onFiles;
  final ValueChanged<bool>? _onHoverChanged;
  bool _isHovering = false;
  bool _isHandlingDrop = false;
  bool _disposed = false;

  static void _attach(NativeFileDropController controller) {
    _controllers.add(controller);
    if (!_handlerRegistered) {
      _handlerRegistered = true;
      fileDropChannel.setMethodCallHandler(_dispatch);
    }
  }

  static void _detach(NativeFileDropController controller) {
    _controllers.remove(controller);
    if (_controllers.isEmpty && _handlerRegistered) {
      _handlerRegistered = false;
      fileDropChannel.setMethodCallHandler(null);
    }
  }

  static Future<Object?> _dispatch(MethodCall call) async {
    if (!supportsFileDrop || _controllers.isEmpty) return null;
    await _controllers.last._handleCall(call);
    return null;
  }

  void _setHovering(bool value) {
    if (_disposed || _isHovering == value) return;
    _isHovering = value;
    _onHoverChanged?.call(value);
  }

  Future<void> _handleCall(MethodCall call) async {
    if (_disposed || !supportsFileDrop) return;
    switch (call.method) {
      case 'dragEnter':
      case 'dragOver':
        _setHovering(true);
      case 'dragLeave':
        _setHovering(false);
      case 'drop':
        _setHovering(false);
        await _handleDrop(call.arguments);
    }
  }

  Future<void> _handleDrop(Object? rawArgs) async {
    if (_isHandlingDrop || _disposed || rawArgs is! List<Object?>) return;
    _isHandlingDrop = true;
    try {
      final List<DroppedFile> dropped = <DroppedFile>[];
      for (final Object? item in rawArgs) {
        if (item is String && item.isNotEmpty) {
          final File file = File(item);
          final FileStat stat = await file.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          dropped.add(
            DroppedFile(
              name: p.basename(item),
              size: stat.size,
              readBytes: file.readAsBytes,
              openStream: file.openRead,
            ),
          );
        } else if (item is Map<Object?, Object?>) {
          final Object? name = item['name'];
          final Object? size = item['size'];
          final Object? bytes = item['bytes'];
          if (name is String && name.isNotEmpty && size is int) {
            final Uint8List payload = bytes is Uint8List ? bytes : Uint8List(0);
            dropped.add(
              DroppedFile(
                name: name,
                size: size,
                readBytes: () async => payload,
              ),
            );
          }
        }
      }
      if (dropped.isNotEmpty && !_disposed) {
        await _onFiles(dropped);
      }
    } finally {
      _isHandlingDrop = false;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _detach(this);
  }
}

FileDropController registerFileDrop(
  Future<void> Function(List<DroppedFile> files) onFiles, {
  ValueChanged<bool>? onHoverChanged,
}) {
  if (!supportsFileDrop) {
    return const NoopFileDropController();
  }
  return NativeFileDropController(onFiles, onHoverChanged: onHoverChanged);
}
