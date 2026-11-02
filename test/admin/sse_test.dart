import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/admin/core/network/api_client.dart';

Stream<List<int>> _chunks(List<String> parts) => Stream.fromIterable([for (final p in parts) utf8.encode(p)]);

void main() {
  test('events split across chunks, multi-byte text, then [DONE] ends it', () async {
    final events = await sseEvents(_chunks([
      'data: {"type":"step","title":"Understanding"}\n\n',
      'data: {"type":"delta","te',
      'xt":"Two DGs — °C"}\n',
      '\n: keep-alive comment\n\n',
      'data: not json\n\n',
      'data: [DONE]\n\n',
      'data: {"type":"delta","text":"after done"}\n\n',
    ])).toList();
    expect(events, [
      {'type': 'step', 'title': 'Understanding'},
      {'type': 'delta', 'text': 'Two DGs — °C'},
    ]);
  });

  test('a last event with no blank line after it is still read', () async {
    final events = await sseEvents(_chunks(['data: {"type":"final","content":"ok"}'])).toList();
    expect(events, [
      {'type': 'final', 'content': 'ok'},
    ]);
  });
}
