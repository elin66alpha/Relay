import 'dart:convert';

/// One decoded Server-Sent Event: an event [type] and its JSON [data] payload.
class BackendEvent {
  const BackendEvent({required this.type, required this.data});

  final String type;
  final Map<String, Object?> data;
}

/// Decode a raw SSE byte stream into [BackendEvent]s.
///
/// Frames are separated by a blank line. Within a frame, `event:` sets the type
/// (defaulting to `message`) and consecutive `data:` lines are joined with
/// newlines — matching the EventSource wire format the backend emits. A leading
/// space after `data:` is stripped per the SSE spec. The terminal frame is
/// emitted even without a trailing blank line so a stream that ends right after
/// its last `data:` line is not dropped.
Stream<BackendEvent> decodeSse(Stream<List<int>> stream) async* {
  String eventType = 'message';
  final StringBuffer data = StringBuffer();
  await for (final String line
      in stream.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        yield BackendEvent(type: eventType, data: decodeSseData(data.toString()));
      }
      eventType = 'message';
      data.clear();
      continue;
    }
    if (line.startsWith('event:')) {
      eventType = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      if (data.isNotEmpty) data.writeln();
      data.write(line.substring(5).trimLeft());
    }
  }
  if (data.isNotEmpty) {
    yield BackendEvent(type: eventType, data: decodeSseData(data.toString()));
  }
}

/// Decode a single SSE frame's `data` payload. Returns the parsed JSON object,
/// or `{'text': <raw>}` when the payload is not a JSON object so a malformed or
/// plain-text payload is surfaced rather than dropped.
Map<String, Object?> decodeSseData(String data) {
  try {
    final Object? decoded = jsonDecode(data);
    if (decoded is Map) return decoded.cast<String, Object?>();
  } on FormatException {
    // Fall through to the plain-text envelope.
  }
  return <String, Object?>{'text': data};
}
