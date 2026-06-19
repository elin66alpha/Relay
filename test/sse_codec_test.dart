import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/backend/sse_codec.dart';

/// Feed [raw] as a single byte chunk, matching how the http stream delivers it.
Stream<List<int>> _wireBytes(String raw) =>
    Stream<List<int>>.value(utf8.encode(raw));

/// Feed [raw] split into byte chunks at the given boundaries, to exercise the
/// decoder across packet splits (a `data:` line arriving in two reads).
Stream<List<int>> _chunked(String raw, List<int> cuts) async* {
  final List<int> bytes = utf8.encode(raw);
  int start = 0;
  for (final int cut in <int>[...cuts, bytes.length]) {
    yield bytes.sublist(start, cut);
    start = cut;
  }
}

void main() {
  group('decodeSseData', () {
    test('parses a JSON object', () {
      expect(decodeSseData('{"a":1,"b":"x"}'),
          <String, Object?>{'a': 1, 'b': 'x'},);
    });

    test('wraps non-JSON payloads as text', () {
      expect(decodeSseData('not json'), <String, Object?>{'text': 'not json'});
    });

    test('wraps non-object JSON (array, number) as text', () {
      expect(decodeSseData('[1,2]'), <String, Object?>{'text': '[1,2]'});
      expect(decodeSseData('42'), <String, Object?>{'text': '42'});
    });
  });

  group('decodeSse', () {
    test('decodes a single framed event with default type', () async {
      final List<BackendEvent> events =
          await decodeSse(_wireBytes('data: {"text":"hi"}\n\n')).toList();
      expect(events, hasLength(1));
      expect(events.single.type, 'message');
      expect(events.single.data, <String, Object?>{'text': 'hi'});
    });

    test('honors an explicit event type', () async {
      final List<BackendEvent> events = await decodeSse(
        _wireBytes('event: segment\ndata: {"requestId":"r1"}\n\n'),
      ).toList();
      expect(events.single.type, 'segment');
      expect(events.single.data, <String, Object?>{'requestId': 'r1'});
    });

    test('joins consecutive data lines with newlines', () async {
      final List<BackendEvent> events = await decodeSse(
        _wireBytes('data: line one\ndata: line two\n\n'),
      ).toList();
      // Not valid JSON, so it falls back to the text envelope with both lines.
      expect(events.single.data, <String, Object?>{'text': 'line one\nline two'});
    });

    test('splits multiple frames on the blank line', () async {
      final List<BackendEvent> events = await decodeSse(
        _wireBytes(
          'event: delta\ndata: {"text":"a"}\n\n'
          'event: agent_done\ndata: {"ok":true}\n\n',
        ),
      ).toList();
      expect(events.map((BackendEvent e) => e.type),
          <String>['delta', 'agent_done'],);
      expect(events[0].data, <String, Object?>{'text': 'a'});
      expect(events[1].data, <String, Object?>{'ok': true});
    });

    test('resets the event type to message between frames', () async {
      final List<BackendEvent> events = await decodeSse(
        _wireBytes('event: segment\ndata: {"a":1}\n\ndata: {"b":2}\n\n'),
      ).toList();
      expect(events[0].type, 'segment');
      expect(events[1].type, 'message');
    });

    test('emits the final frame even without a trailing blank line', () async {
      final List<BackendEvent> events =
          await decodeSse(_wireBytes('data: {"text":"tail"}')).toList();
      expect(events.single.data, <String, Object?>{'text': 'tail'});
    });

    test('ignores blank lines that carry no data', () async {
      final List<BackendEvent> events =
          await decodeSse(_wireBytes('\n\n\ndata: {"a":1}\n\n')).toList();
      expect(events, hasLength(1));
    });

    test('trims all leading whitespace after data:', () async {
      final List<BackendEvent> events =
          await decodeSse(_wireBytes('data:   {"text":"x"}\n\n')).toList();
      // trimLeft drops every leading space, so the JSON still parses.
      expect(events.single.data, <String, Object?>{'text': 'x'});
    });

    test('reassembles a frame split across byte chunks', () async {
      // Cut inside the event line and inside the JSON payload, so a correct
      // decoder must buffer across reads before the line/frame completes.
      final List<BackendEvent> events = await decodeSse(
        _chunked('event: delta\ndata: {"text":"hello"}\n\n', <int>[6, 20, 30]),
      ).toList();
      expect(events.single.type, 'delta');
      expect(events.single.data, <String, Object?>{'text': 'hello'});
    });
  });
}
