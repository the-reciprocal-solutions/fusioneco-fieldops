import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/conversation/conversation_outbox.dart';
import 'package:technician_portal/core/network/api_exception.dart';
import 'package:technician_portal/domain/conversation.dart';

/// Hand-written fake of the poster seam (no mocking library in this repo).
/// Each call pops the next scripted answer.
class _FakePoster implements ConversationPoster {
  _FakePoster(this.script);
  final List<Object> script;
  final calls = <({String body, String clientId, String? replyTo})>[];

  @override
  Future<PostOutcome> post(ConvEntity entity, String id, {required String body, required String clientId, String? replyTo}) async {
    calls.add((body: body, clientId: clientId, replyTo: replyTo));
    final next = script.removeAt(0);
    if (next is ApiFailure) throw next;
    return next as PostOutcome;
  }
}

const _me = ConvAuthor(type: ConvAuthorType.user, id: 'u-me', name: 'Balaji');

PostSent _sent(String id, String clientId) => PostSent(PostMessageResult.fromJson({
  'message': {'id': id, 'author': {'type': 'user', 'id': 'u-me', 'name': 'Balaji'}, 'body': 'b', 'createdAt': '2026-09-30T08:00:00Z', 'clientId': clientId},
  'invoked': [],
  'notes': [],
}));

void main() {
  test('sent: the local copy goes and the server message comes back', () async {
    final box = ConversationOutbox();
    box.draft(me: _me, body: '@agent check photos', clientId: 'c1', replyTo: 'm0');
    expect(box.messages.single.outgoing, OutgoingState.sending);
    final poster = _FakePoster([_sent('s1', 'c1')]);
    final r = await box.send(poster, ConvEntity.snag, 'SN-1', 'c1');
    expect(r!.message.id, 's1');
    expect(box.isEmpty, isTrue);
    expect(poster.calls.single.replyTo, 'm0');
  });

  test('offline: stays visible as queued (the offline queue replays it)', () async {
    final box = ConversationOutbox();
    box.draft(me: _me, body: 'hi', clientId: 'c1');
    final r = await box.send(_FakePoster([const PostQueued()]), ConvEntity.snag, 'SN-1', 'c1');
    expect(r, isNull);
    expect(box.messages.single.outgoing, OutgoingState.queued);
  });

  test('server refusal: failed with the reason, Retry re-sends the same clientId', () async {
    final box = ConversationOutbox();
    box.draft(me: _me, body: 'hi', clientId: 'c1');
    final poster = _FakePoster([
      const HttpFailure(status: 503, message: 'Server busy'),
      _sent('s1', 'c1'),
    ]);
    await box.send(poster, ConvEntity.workOrder, 'WO-1', 'c1');
    expect(box.messages.single.outgoing, OutgoingState.failed);
    // A 5xx's text is never shown raw (2026-10-06): an i18n key, worded on screen.
    expect(box.messages.single.failure, 'conv.err_server');

    final r = await box.send(poster, ConvEntity.workOrder, 'WO-1', 'c1');
    expect(r, isNotNull);
    expect(poster.calls.map((c) => c.clientId).toSet(), {'c1'}, reason: 'the server de-duplicates by clientId');
    expect(box.isEmpty, isTrue);
  });

  test('discard drops a failed message', () async {
    final box = ConversationOutbox();
    box.draft(me: _me, body: 'hi', clientId: 'c1');
    await box.send(_FakePoster([const HttpFailure(status: 400, message: 'Too long')]), ConvEntity.snag, 'x', 'c1');
    box.discard('c1');
    expect(box.isEmpty, isTrue);
  });

  test('syncQueued: restores queued messages after a restart and drops replayed ones', () {
    final box = ConversationOutbox();
    final fromQueue = [
      ConvMessage(id: 'local:q1', author: _me, body: 'one', createdAt: DateTime(2026, 9, 30, 8), clientId: 'q1', outgoing: OutgoingState.queued),
      ConvMessage(id: 'local:q2', author: _me, body: 'two', createdAt: DateTime(2026, 9, 30, 9), clientId: 'q2', outgoing: OutgoingState.queued),
    ];
    box.syncQueued(fromQueue);
    expect(box.messages.map((m) => m.body).toList(), ['one', 'two']);

    // q1 replayed (left the queue).
    box.syncQueued([fromQueue[1]]);
    expect(box.messages.map((m) => m.clientId).toList(), ['q2']);
  });

  test('dropEchoed removes a sent local copy once the server shows it', () {
    final box = ConversationOutbox();
    box.draft(me: _me, body: 'hi', clientId: 'c1');
    box.dropEchoed([
      ConvMessage(id: 's1', author: _me, body: 'hi', createdAt: DateTime(2026), clientId: 'c1'),
    ]);
    expect(box.isEmpty, isTrue);
  });
}
