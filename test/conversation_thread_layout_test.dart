import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/conversation/thread_layout.dart';
import 'package:technician_portal/domain/conversation.dart';

const _me = ConvAuthor(type: ConvAuthorType.user, id: 'u-me', name: 'Balaji K');
const _ops = ConvAuthor(type: ConvAuthorType.user, id: 'u-ops', name: 'Ops Admin');
const _flow = ConvAuthor(type: ConvAuthorType.agent, id: 'a-00', name: 'Flow Agent');

ConvMessage _m(String id, ConvAuthor a, DateTime at, {String? replyTo, String? clientId, bool mine = false}) =>
    ConvMessage(id: id, author: a, body: id, createdAt: at, replyTo: replyTo, clientId: clientId, mine: mine);

void main() {
  final d1 = DateTime(2026, 9, 29, 9, 0);
  final d2 = DateTime(2026, 9, 30, 8, 0);

  group('layoutThread', () {
    test('day dividers and same-author grouping inside 5 minutes', () {
      final items = layoutThread([
        _m('a', _ops, d1),
        _m('b', _ops, d1.add(const Duration(minutes: 2))),
        _m('c', _ops, d1.add(const Duration(minutes: 20))),
        _m('d', _me, d2),
      ]);
      expect(items.whereType<DayDivider>().length, 2);
      final msgs = items.whereType<MessageItem>().toList();
      expect(msgs.map((m) => m.showHeader).toList(), [true, false, true, true]);
    });

    test('an agent never shares a header with a person of the same id', () {
      final items = layoutThread([
        _m('a', _ops, d1),
        _m('b', const ConvAuthor(type: ConvAuthorType.agent, id: 'u-ops', name: 'x'), d1.add(const Duration(seconds: 10))),
      ]);
      expect(items.whereType<MessageItem>().last.showHeader, isTrue);
    });

    test('unread divider sits before the first unread message by someone else', () {
      final items = layoutThread(
        [
          _m('a', _ops, d1),
          _m('b', _me, d1.add(const Duration(minutes: 30))), // mine — never unread
          _m('c', _flow, d1.add(const Duration(minutes: 31))),
          _m('d', _ops, d1.add(const Duration(minutes: 32))),
        ],
        lastReadAt: d1.add(const Duration(minutes: 10)),
        myIds: {'u-me'},
      );
      final i = items.indexWhere((x) => x is UnreadDivider);
      expect((items[i] as UnreadDivider).count, 2);
      expect((items[i + 1] as MessageItem).message.id, 'c');
    });

    test('replies carry their parent; a parent outside the page is flagged', () {
      final items = layoutThread([
        _m('a', _me, d1),
        _m('b', _flow, d1.add(const Duration(minutes: 1)), replyTo: 'a'),
        _m('c', _flow, d1.add(const Duration(minutes: 2)), replyTo: 'gone'),
      ]).whereType<MessageItem>().toList();
      expect(items[1].parent?.id, 'a');
      expect(items[1].showHeader, isTrue, reason: 'a reply always shows who wrote it');
      expect(items[2].parentMissing, isTrue);
    });

    test('socket messages (mine: false on the wire) count as mine by author id', () {
      expect(isMine(_m('x', _me, d1), {'u-me'}), isTrue);
      expect(isMine(_m('x', _ops, d1), {'u-me'}), isFalse);
    });
  });

  test('replyTargetFor keeps replies one level deep', () {
    expect(replyTargetFor(_m('b', _flow, d1, replyTo: 'a')), 'a');
    expect(replyTargetFor(_m('a', _me, d1)), 'a');
  });

  test('mergeWithLocal drops local copies the server echoed by clientId', () {
    final server = [_m('s1', _me, d1, clientId: 'c1')];
    final local = [
      _m('local:c1', _me, d1, clientId: 'c1'),
      _m('local:c2', _me, d2, clientId: 'c2'),
    ];
    expect(mergeWithLocal(server, local).map((m) => m.id).toList(), ['s1', 'local:c2']);
  });

  test('upsertMessage replaces by id and keeps the GET\'s mine flag', () {
    final list = [_m('a', _me, d1, mine: true), _m('b', _ops, d2)];
    final edited = ConvMessage(id: 'a', author: _me, body: '', createdAt: d1, deletedAt: d2);
    final next = upsertMessage(list, edited);
    expect(next.first.isDeleted, isTrue);
    expect(next.first.mine, isTrue);
    final added = upsertMessage(list, _m('z', _flow, d1.add(const Duration(hours: 1))));
    expect(added.map((m) => m.id).toList(), ['a', 'z', 'b']);
  });

  group('contract parsing (server C1/C2)', () {
    test('an agent reply with routing, cards, follow-ups and grounding', () {
      final m = ConvMessage.fromJson({
        'id': 'r1',
        'author': {'type': 'agent', 'id': 'a-00', 'name': 'Flow Agent', 'role': 'picks the right specialist'},
        'body': '**Photo 2** does not show the defect.',
        'replyTo': 'm1',
        'createdAt': '2026-09-30T08:00:00Z',
        'kind': 'message',
        'grounding': {'checked': 9, 'grounded': 9, 'dropped': 0},
        'cards': [
          {'kind': 'flag_photo', 'title': 'Flag photo 2', 'status': 'suggested', 'draftId': 'd1'},
        ],
        'routing': {
          'rule': 'keywords',
          'line': 'Routing to Visual Inspector (photos)',
          'agents': [
            {'templateId': 'A47', 'name': 'Visual Inspector', 'reason': 'photos'},
          ],
        },
        'followUps': [
          {'id': 'f1', 'label': 'Check this again tomorrow at 09:00', 'kind': 'schedule', 'draft': {'kind': 'agent_task'}},
        ],
      });
      expect(m.isAgent, isTrue);
      expect(m.grounding!.grounded, 9);
      expect(m.cards.single.status, ActionCardStatus.suggested);
      expect(m.routing!.line, 'Routing to Visual Inspector (photos)');
      expect(m.followUps.single.draft['kind'], 'agent_task');
    });

    test('a schedule card wrapper, and a deleted one', () {
      final card = ConvMessage.fromJson({
        'id': 's1',
        'author': {'type': 'agent', 'id': 'a', 'name': 'Flow Agent'},
        'body': 'Done — I set this up.',
        'createdAt': '2026-09-30T08:00:00Z',
        'schedule': {
          'scheduleId': 'sch-1',
          'schedule': {'id': 'sch-1', 'kind': 'reminder', 'title': 'Check PM compliance', 'human': 'Every Monday 08:00', 'status': 'active'},
        },
      });
      expect(card.schedules.single.cadenceText, 'Every Monday 08:00');
      expect(card.scheduleDeleted, isFalse);

      final gone = ConvMessage.fromJson({
        'id': 's2',
        'author': {'type': 'agent', 'id': 'a', 'name': 'Flow Agent'},
        'body': 'x',
        'createdAt': '2026-09-30T08:00:00Z',
        'schedule': {'scheduleId': 'sch-2', 'schedule': null},
      });
      expect(gone.schedules, isEmpty);
      expect(gone.scheduleDeleted, isTrue);
    });

    test('clarify question', () {
      final m = ConvMessage.fromJson({
        'id': 'q',
        'author': {'type': 'agent', 'id': 'a', 'name': 'Flow Agent'},
        'body': 'How often?',
        'createdAt': '2026-09-30T08:00:00Z',
        'clarify': {'question': 'How often should I check?', 'pendingText': 'every so often'},
      });
      expect(m.clarify, 'How often should I check?');
    });

    test('session with specialists; elapsed counts from receipt, not the phone clock', () {
      final s = ConvSession.fromJson({
        'id': 'sess',
        'agentId': 'a-00',
        'agentName': 'Flow Agent',
        'messageId': 'm1',
        'status': 'working',
        'startedAt': '2020-01-01T00:00:00Z', // a phone clock far off
        'elapsedMs': 42000,
        'requesterId': 'u-me',
        'specialists': [
          {'agentName': 'Visual Inspector', 'status': 'running', 'stage': 'reading 3 photos'},
          {'agentName': 'SLA Guardian', 'status': 'completed', 'stage': null},
        ],
      });
      expect(s.isLive, isTrue);
      expect(s.specialists.first.status, SessionStatus.working);
      expect(s.specialists.last.status, SessionStatus.replied);
      final shown = DateTime.now().difference(s.countFrom);
      expect(shown.inSeconds, inInclusiveRange(41, 44));
      expect(ConvSession.fromJson({'status': 'stopped'}).status, SessionStatus.stopped);
    });

    test('POST result: invoked sessions point at the posted message', () {
      final r = PostMessageResult.fromJson({
        'message': {'id': 'm9', 'author': {'type': 'user', 'id': 'u-me', 'name': 'B'}, 'body': '@agent hi', 'createdAt': '2026-09-30T08:00:00Z', 'clientId': 'c9'},
        'invoked': [
          {'agentId': 'a-00', 'runId': 'r', 'agentName': 'Flow Agent', 'sessionId': 's9'},
        ],
        'notes': [
          {'code': 'busy', 'text': 'Visual Inspector is already looking at this thread.'},
        ],
      });
      expect(r.invoked.single.id, 's9');
      expect(r.invoked.single.messageId, 'm9');
      expect(r.invoked.single.status, SessionStatus.queued);
      expect(r.notes.single.code, 'busy');
      expect(r.message.clientId, 'c9');
    });

    test('thread flags', () {
      final t = ConversationThread.fromJson({
        'entity': 'snag',
        'entityId': 'uuid',
        'record': {'ref': 'SN-00001', 'title': 'Issues box'},
        'messages': [],
        'me': {'following': true, 'muted': false, 'lastReadAt': null},
        'canMentionAgents': true,
        'canApproveCards': false,
      }, fallbackEntity: ConvEntity.snag);
      expect(t.canMentionAgents, isTrue);
      expect(t.canApproveCards, isFalse);
      expect(t.following, isTrue);
      expect(t.record.ref, 'SN-00001');
    });
  });
}
