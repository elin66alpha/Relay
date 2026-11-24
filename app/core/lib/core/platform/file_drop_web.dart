import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'file_drop_stub.dart';
import 'platform_capabilities.dart';

class WebFileDropController implements FileDropController {
  WebFileDropController(this._onFiles, {ValueChanged<bool>? onHoverChanged})
      : _onHoverChanged = onHoverChanged {
    _dragEnterHandler = ((web.Event event) {
      final web.DragEvent dragEvent = event as web.DragEvent;
      if (!_hasFiles(dragEvent)) return;
      event.preventDefault();
      _dragDepth += 1;
      _setHovering(true);
    }).toJS;
    _dragOverHandler = ((web.Event event) {
      final web.DragEvent dragEvent = event as web.DragEvent;
      if (!_hasFiles(dragEvent)) return;
      event.preventDefault();
      final web.DataTransfer? transfer = dragEvent.dataTransfer;
      if (transfer != null) transfer.dropEffect = 'copy';
      _setHovering(true);
    }).toJS;
    _dragLeaveHandler = ((web.Event event) {
      final web.DragEvent dragEvent = event as web.DragEvent;
      if (_dragDepth > 0) _dragDepth -= 1;
      if (_dragDepth == 0 || dragEvent.relatedTarget == null) {
        _dragDepth = 0;
        _setHovering(false);
      }
    }).toJS;
    _dropHandler = ((web.Event event) {
      event.preventDefault();
      _dragDepth = 0;
      _setHovering(false);
      unawaited(_handleDrop(event as web.DragEvent));
    }).toJS;

    web.window.addEventListener('dragenter', _dragEnterHandler);
    web.window.addEventListener('dragover', _dragOverHandler);
    web.window.addEventListener('dragleave', _dragLeaveHandler);
    web.window.addEventListener('drop', _dropHandler);
  }

  final Future<void> Function(List<DroppedFile> files) _onFiles;
  final ValueChanged<bool>? _onHoverChanged;
  late final web.EventListener _dragEnterHandler;
  late final web.EventListener _dragOverHandler;
  late final web.EventListener _dragLeaveHandler;
  late final web.EventListener _dropHandler;
  int _dragDepth = 0;
  bool _isHovering = false;
  bool _isHandlingDrop = false;
  bool _disposed = false;

  bool _hasFiles(web.DragEvent event) {
    final web.DataTransfer? transfer = event.dataTransfer;
    if (transfer == null) return false;
    for (final JSString type in transfer.types.toDart) {
      if (type.toDart == 'Files') return true;
    }
    return transfer.files.length > 0;
  }

  void _setHovering(bool value) {
    if (_disposed || _isHovering == value) return;
    _isHovering = value;
    _onHoverChanged?.call(value);
  }

  Future<void> _handleDrop(web.DragEvent event) async {
    if (_isHandlingDrop || _disposed) return;
    _isHandlingDrop = true;
    try {
      final web.FileList? files = event.dataTransfer?.files;
      if (files == null || files.length == 0) return;

      final List<DroppedFile> dropped = <DroppedFile>[];
      for (int i = 0; i < files.length; i += 1) {
        final web.File? file = files.item(i);
        if (file == null) continue;
        dropped.add(
          DroppedFile(
            name: file.name,
            size: file.size,
            readBytes: () async =>
                (await file.arrayBuffer().toDart).toDart.asUint8List(),
          ),
        );
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
    web.window.removeEventListener('dragenter', _dragEnterHandler);
    web.window.removeEventListener('dragover', _dragOverHandler);
    web.window.removeEventListener('dragleave', _dragLeaveHandler);
    web.window.removeEventListener('drop', _dropHandler);
  }
}

FileDropController registerFileDrop(
  Future<void> Function(List<DroppedFile> files) onFiles, {
  ValueChanged<bool>? onHoverChanged,
}) {
  if (!supportsFileDrop) {
    return const NoopFileDropController();
  }
  return WebFileDropController(onFiles, onHoverChanged: onHoverChanged);
}
