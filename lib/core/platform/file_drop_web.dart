import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'file_drop_stub.dart';

class WebFileDropController implements FileDropController {
  WebFileDropController(this._onFiles) {
    _dragOverHandler = ((web.Event event) {
      event.preventDefault();
      final web.DataTransfer? transfer = (event as web.DragEvent).dataTransfer;
      if (transfer != null) transfer.dropEffect = 'copy';
    }).toJS;
    _dropHandler = ((web.Event event) {
      event.preventDefault();
      unawaited(_handleDrop(event as web.DragEvent));
    }).toJS;

    web.window.addEventListener('dragover', _dragOverHandler);
    web.window.addEventListener('drop', _dropHandler);
  }

  final Future<void> Function(List<DroppedFile> files) _onFiles;
  late final web.EventListener _dragOverHandler;
  late final web.EventListener _dropHandler;
  bool _isHandlingDrop = false;

  Future<void> _handleDrop(web.DragEvent event) async {
    if (_isHandlingDrop) return;
    _isHandlingDrop = true;
    try {
      final web.FileList? files = event.dataTransfer?.files;
      if (files == null || files.length == 0) return;

      final List<DroppedFile> dropped = <DroppedFile>[];
      for (int i = 0; i < files.length; i += 1) {
        final web.File? file = files.item(i);
        if (file == null) continue;
        final ByteBuffer buffer = (await file.arrayBuffer().toDart).toDart;
        dropped.add(
          DroppedFile(
            name: file.name,
            bytes: buffer.asUint8List(),
          ),
        );
      }
      if (dropped.isNotEmpty) {
        await _onFiles(dropped);
      }
    } finally {
      _isHandlingDrop = false;
    }
  }

  @override
  void dispose() {
    web.window.removeEventListener('dragover', _dragOverHandler);
    web.window.removeEventListener('drop', _dropHandler);
  }
}

FileDropController registerFileDrop(
  Future<void> Function(List<DroppedFile> files) onFiles,
) =>
    WebFileDropController(onFiles);
