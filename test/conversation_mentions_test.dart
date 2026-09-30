import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/conversation/mention_parser.dart';
import 'package:technician_portal/domain/conversation.dart';

MentionCandidate _agent(String handle, String name) =>
    MentionCandidate(type: ConvAuthorType.agent, id: handle, name: name, handle: handle);
MentionCandidate _person(String handle, String name) =>
    MentionCandidate(type: ConvAuthorType.user, id: handle, name: name, handle: handle);

void main() {
  group('activeMention', () {
    test('finds the @query right before the cursor', () {
      const text = 'hey @vis';
      final q = activeMention(text, text.length)!;
      expect(q.start, 4);
      expect(q.query, 'vis');
    });

    test('a bare @ opens the picker with an empty query', () {
      expect(activeMention('@', 1)!.query, '');
      expect(activeMention('please @', 8)!.query, '');
    });

    test('an email address never opens the picker', () {
      const text = 'mail ali@site';
      expect(activeMention(text, text.length), isNull);
    });

    test('closes once a space follows the handle', () {
      const text = '@agent check';
      expect(activeMention(text, text.length), isNull);
    });

    test('works for Arabic names', () {
      const text = 'مرحبا @أحم';
      expect(activeMention(text, text.length)!.query, 'أحم');
    });
  });

  group('insertMention', () {
    test('replaces the query with the handle and a trailing space', () {
      const text = 'ask @vi please';
      final q = activeMention(text, 7)!;
      final r = insertMention(text, q, 'visual-inspector');
      expect(r.text, 'ask @visual-inspector please');
      expect(r.cursor, 'ask @visual-inspector'.length + 1);
    });

    test('swallows the rest of a half-typed handle', () {
      const text = '@agxyz';
      final q = activeMention(text, 3)!; // cursor after "@ag"
      expect(insertMention(text, q, 'agent').text, '@agent ');
    });
  });

  group('mentionHandles / mentionsAgent', () {
    test('lists handles in order without duplicates or trailing dots', () {
      expect(mentionHandles('@Agent look, then ask @sla-guardian. Thanks @agent'), ['agent', 'sla-guardian']);
    });

    test('ignores emails', () {
      expect(mentionHandles('send to a@b.com'), isEmpty);
    });

    test('every orchestrator alias counts as asking an agent', () {
      for (final h in ['agent', 'flowagent', 'orbit', 'ai']) {
        expect(mentionsAgent('@$h check this'), isTrue, reason: h);
      }
      expect(mentionsAgent('@balaji check this'), isFalse);
      expect(mentionsAgent('@visual-inspector look', agentHandles: {'Visual-Inspector'}), isTrue);
    });
  });

  test('looksLikeScheduleRequest spots reminder phrasing (EN + AR)', () {
    expect(looksLikeScheduleRequest('remind me every Monday at 8 to check PM compliance'), isTrue);
    expect(looksLikeScheduleRequest('check this again tomorrow at 9'), isTrue);
    expect(looksLikeScheduleRequest('tell me when WO-161 is closed'), isTrue);
    expect(looksLikeScheduleRequest('ذكرني غدا'), isTrue);
    expect(looksLikeScheduleRequest('the photo is blurry'), isFalse);
  });

  group('pickerCandidates', () {
    final fetched = [
      _person('balaji', 'Balaji K'),
      _agent('visual-inspector', 'Visual Inspector'),
      _agent('agent', 'Flow Agent'), // the server's own @agent row — deduped
      _agent('sla-guardian', 'SLA Guardian'),
    ];

    test('@agent first, then specialists, then people', () {
      final list = pickerCandidates(
        query: '',
        fetched: fetched,
        canMentionAgents: true,
        orchestratorName: 'Flow Agent',
        orchestratorRole: 'picks the right specialist',
      );
      expect(list.map((c) => c.handle).toList(), ['agent', 'visual-inspector', 'sla-guardian', 'balaji']);
      expect(list.first.orchestrator, isTrue);
    });

    test('no agents at all when the role may not ask them', () {
      final list = pickerCandidates(
        query: '',
        fetched: fetched,
        canMentionAgents: false,
        orchestratorName: 'Flow Agent',
        orchestratorRole: '',
      );
      expect(list.map((c) => c.handle).toList(), ['balaji']);
    });

    test('filters by handle prefix or name', () {
      List<String> pick(String q) => pickerCandidates(
        query: q,
        fetched: fetched,
        canMentionAgents: true,
        orchestratorName: 'Flow Agent',
        orchestratorRole: '',
      ).map((c) => c.handle).toList();
      expect(pick('fl'), ['agent'], reason: 'the @flowagent alias / "Flow Agent"');
      expect(pick('ba'), ['balaji']);
      expect(pick('insp'), ['visual-inspector']);
    });

    test('offline: falls back to the thread participants', () {
      final list = pickerCandidates(
        query: 'ra',
        fetched: const [],
        canMentionAgents: true,
        orchestratorName: 'Flow Agent',
        orchestratorRole: '',
        fallbackPeople: [_person('ravi', 'Ravi S')],
      );
      expect(list.map((c) => c.handle).toList(), ['ravi']);
    });
  });
}
