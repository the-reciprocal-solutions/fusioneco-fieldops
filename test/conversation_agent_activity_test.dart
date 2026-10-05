import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/conversation/agent_activity.dart';
import 'package:technician_portal/core/conversation/conversation_outbox.dart';
import 'package:technician_portal/core/conversation/mention_parser.dart';
import 'package:technician_portal/core/network/api_exception.dart';
import 'package:technician_portal/domain/conversation.dart';

/// The rules behind "show the agent's work" (2026-10-06): steps come only
/// from server stages, stuck sessions stop pretending to work, a bad end
/// says so, and post failures read in plain words.
ConvSession _s(String id, String status, {Duration ago = Duration.zero, String? stage, String agentId = 'a-00', List<Map<String, dynamic>> specialists = const [], String? replyId, String messageId = 'm1'}) =>
    ConvSession.fromJson({
      'id': id,
      'agentId': agentId,
      'agentName': 'Flow Agent',
      'messageId': messageId,
      'status': status,
      'stage': ?stage,
      'replyId': ?replyId,
      'elapsedMs': ago.inMilliseconds,
      'startedAt': DateTime.now().subtract(ago).toUtc().toIso8601String(),
      'specialists': specialists,
    });

ConvMessage _m(String id, {bool agent = false, String? replyTo, String kind = 'message'}) => ConvMessage.fromJson({
  'id': id,
  'author': {'type': agent ? 'agent' : 'user', 'id': agent ? 'a-00' : 'u1', 'name': agent ? 'Flow Agent' : 'Ravi'},
  'body': 'x',
  'replyTo': ?replyTo,
  'kind': kind,
  'createdAt': '2026-10-06T08:00:00Z',
});

void main() {
  group('steps', () {
    test('a stage is added once; a repeated poll is not a new step', () {
      var t = appendStep(const [], 'reading the record');
      t = appendStep(t, 'reading the record');
      t = appendStep(t, 'thinking it through');
      t = appendStep(t, null);
      t = appendStep(t, '  ');
      expect(t, ['reading the record', 'thinking it through']);
    });

    test('an unchanged trail is the same list (no rebuild)', () {
      final t = ['a'];
      expect(identical(appendStep(t, 'a'), t), isTrue);
      final trails = {'s1': t};
      expect(identical(recordSession(trails, _s('s1', 'working', stage: 'a')), trails), isTrue);
    });

    test('keeps the newest $kMaxTrailSteps steps', () {
      var t = const <String>[];
      for (var i = 0; i < kMaxTrailSteps + 3; i++) {
        t = appendStep(t, 'step $i');
      }
      expect(t.length, kMaxTrailSteps);
      expect(t.last, 'step ${kMaxTrailSteps + 2}');
    });

    test('a session records its own stage then each specialist as "Name · stage"', () {
      final trails = recordSession(const {}, _s('s1', 'working', stage: 'routing', specialists: [
        {'agentName': 'Visual Inspector', 'status': 'running', 'stage': 'checking photos'},
        {'agentName': 'SLA Guardian', 'status': 'running'},
      ]));
      expect(trails['s1'], ['routing', 'Visual Inspector · checking photos']);
    });

    test('typing goes to the session of the agent that typed, else the only live one', () {
      final a = _s('s1', 'working', agentId: 'a-00');
      final b = _s('s2', 'replied', agentId: 'a-47');
      expect(sessionForTyping([a, b], 'a-00')?.id, 's1');
      expect(sessionForTyping([a, b], 'a-47-child')?.id, 's1', reason: 'a specialist typing for the only live session');
      expect(sessionForTyping([a, _s('s3', 'queued', agentId: 'x')], 'nobody'), isNull);
    });
  });

  group('live / stuck', () {
    test('a session queued for 30+ min is not shown as working (lost run)', () {
      final now = DateTime.now();
      final fresh = _s('s1', 'working', ago: const Duration(minutes: 3));
      final stuck = _s('s2', 'queued', ago: const Duration(minutes: 45));
      final done = _s('s3', 'replied');
      expect(visibleLiveSessions([fresh, stuck, done], now).map((s) => s.id), ['s1']);
      expect(isStaleSession(stuck, now), isTrue);
    });

    test('queued for over 2 minutes → "still waiting" (working never is)', () {
      final now = DateTime.now();
      expect(isWaitingLong(_s('s1', 'queued', ago: const Duration(minutes: 3)), now), isTrue);
      expect(isWaitingLong(_s('s1', 'queued', ago: const Duration(seconds: 30)), now), isFalse);
      expect(isWaitingLong(_s('s1', 'working', ago: const Duration(minutes: 9)), now), isFalse);
    });
  });

  group('ended without a reply', () {
    test('live → failed with no agent reply → reported', () {
      final before = [_s('s1', 'working')];
      final after = [_s('s1', 'failed')];
      expect(endedWithoutReply(before, after, [_m('m1')]).map((s) => s.id), ['s1']);
    });

    test('the agent replied (by replyId or replyTo) → nothing to report', () {
      final before = [_s('s1', 'working')];
      expect(endedWithoutReply(before, [_s('s1', 'failed', replyId: 'r1')], [_m('r1', agent: true)]), isEmpty);
      expect(endedWithoutReply(before, [_s('s1', 'stopped')], [_m('r2', agent: true, replyTo: 'm1')]), isEmpty);
    });

    test('the routing line (system) is not a reply', () {
      final before = [_s('s1', 'queued')];
      expect(
        endedWithoutReply(before, [_s('s1', 'failed')], [_m('line', agent: true, replyTo: 'm1', kind: 'system')]).length,
        1,
      );
    });

    test('replied, or never live on this phone → nothing', () {
      expect(endedWithoutReply([_s('s1', 'working')], [_s('s1', 'replied')], const []), isEmpty);
      expect(endedWithoutReply(const [], [_s('s1', 'failed')], const []), isEmpty);
    });
  });

  group('the @agent post', () {
    test('the chip / picker text is an @agent mention the server reads as the Orchestrator', () {
      final q = activeMention('@ag', 3)!;
      final r = insertMention('@ag', q, kOrchestratorHandle);
      expect(r.text, '@agent ');
      expect(mentionsAgent('${r.text}remind me tomorrow at 9 to check the pump'), isTrue);
      expect(looksLikeScheduleRequest('@agent remind me tomorrow at 9 to check the pump'), isTrue);
    });

    test("the server's invoked rows {agentId, runId, agentName, sessionId} become live sessions on the mention", () {
      final r = PostMessageResult.fromJson({
        'message': {'id': 'm1', 'author': {'type': 'user', 'id': 'u1', 'name': 'Ravi'}, 'body': '@agent is this fixed?', 'createdAt': '2026-10-06T08:00:00Z'},
        'invoked': [
          {'agentId': 'a-00', 'runId': 'run-1', 'agentName': 'Flow Agent', 'sessionId': 'sess-1'},
        ],
        'notes': [],
      });
      expect(r.invoked.single.id, 'sess-1');
      expect(r.invoked.single.messageId, 'm1');
      expect(r.invoked.single.status, SessionStatus.queued);
      expect(r.invoked.single.isLive, isTrue);
    });
  });

  group('post failures in plain words', () {
    test('location gate 428 / signed out 401 / server 5xx / no response → keys, never raw text', () {
      expect(plainPostFailure(const HttpFailure(status: 428, message: 'POST your current position to /fm/technicians/me/location.')), 'conv.err_location');
      expect(plainPostFailure(const HttpFailure(status: 401, message: 'Unauthorized')), 'conv.err_signed_out');
      expect(plainPostFailure(const HttpFailure(status: 503, message: 'upstream connect error')), 'conv.err_server');
      expect(plainPostFailure(const UnknownFailure('SocketException: …')), 'conv.err_server');
    });

    test("the server's own 4xx words are kept", () {
      expect(plainPostFailure(const HttpFailure(status: 400, message: 'Keep the message under 4000 characters.')), 'Keep the message under 4000 characters.');
    });
  });
}
