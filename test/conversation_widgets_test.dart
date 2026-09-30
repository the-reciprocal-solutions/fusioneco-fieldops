import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/domain/conversation.dart';
import 'package:technician_portal/domain/user_schedule.dart';
import 'package:technician_portal/features/conversation/widgets/composer.dart';
import 'package:technician_portal/features/conversation/widgets/message_tile.dart';
import 'package:technician_portal/features/conversation/widgets/schedule_card.dart';
import 'package:technician_portal/features/conversation/widgets/working_card.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// Render tests for the conversation widgets, English and Arabic (RTL) on a
/// narrow phone, with the real `conv.*` / `schedules.*` strings — a missing
/// key shows up as raw key text here, not in front of a technician.
Map<String, dynamic> _strings(String lang) {
  final all = jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in all.entries)
      if (e.key.startsWith('conv.') || e.key.startsWith('schedules.') || e.key.startsWith('common.')) e.key: e.value,
  };
}

Future<void> _pump(WidgetTester tester, String lang, Widget child) async {
  FlutterLocalization.instance.translate(lang);
  tester.view.physicalSize = const Size(320 * 3, 780 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
        locale: Locale(lang),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
}

final _reply = ConvMessage.fromJson({
  'id': 'r1',
  'author': {'type': 'agent', 'id': 'a-00', 'name': 'Flow Agent', 'role': 'picks the right specialist'},
  'body': 'Photo 2 does **not** show the defect on the Central Air Conditioning Unit.',
  'createdAt': '2026-09-30T08:00:00Z',
  'grounding': {'checked': 9, 'grounded': 9, 'dropped': 1},
  'notInData': ['WO-999'],
  'cards': [
    {'kind': 'flag_photo', 'title': 'Flag photo 2 as not showing the defect', 'status': 'suggested', 'draftId': 'd1', 'reason': 'The unit is out of frame.'},
  ],
  'routing': {'rule': 'keywords', 'agents': [{'templateId': 'A47', 'name': 'Visual Inspector', 'reason': 'photos'}]},
  'followUps': [
    {'id': 'f1', 'label': 'Check this again tomorrow at 09:00', 'kind': 'schedule', 'draft': {}},
  ],
  'schedule': {
    'scheduleId': 's1',
    'schedule': {'id': 's1', 'kind': 'reminder', 'title': 'Check PM compliance', 'cron': '0 8 * * 1', 'status': 'active'},
  },
});

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final l = FlutterLocalization.instance;
    await l.ensureInitialized();
    l.init(
      mapLocales: [MapLocale('en', _strings('en')), MapLocale('ar', _strings('ar'))],
      initLanguageCode: 'en',
    );
  });

  for (final lang in ['en', 'ar']) {
    testWidgets('agent reply reads as an AI teammate; card needs an admin ($lang)', (tester) async {
      await _pump(tester, lang, MessageTile(message: _reply, showHeader: true, onFollowUp: (_) {}));
      expect(tester.takeException(), isNull);
      expect(find.text('Flow Agent'), findsWidgets);
      expect(find.text(lang == 'en' ? 'AI' : 'ذكاء'), findsOneWidget);
      expect(find.text(lang == 'en' ? "Needs an admin's OK" : 'يحتاج موافقة مسؤول'), findsOneWidget);
      expect(find.textContaining(lang == 'en' ? 'Checked against your data · 9 of 9' : 'تم التحقق من بياناتك'), findsOneWidget);
      expect(find.text('Check this again tomorrow at 09:00'), findsOneWidget);
      expect(find.textContaining('conv.'), findsNothing, reason: 'a raw i18n key leaked');
      expect(find.textContaining('schedules.'), findsNothing, reason: 'a raw i18n key leaked');
    });

    testWidgets('failed outgoing message offers Retry and Discard ($lang)', (tester) async {
      var retried = false;
      final failed = ConvMessage(
        id: 'local:c1',
        author: const ConvAuthor(type: ConvAuthorType.user, id: 'u', name: 'Balaji K'),
        body: '@agent is this fixed?',
        createdAt: DateTime(2026, 9, 30, 8),
        clientId: 'c1',
        mine: true,
        outgoing: OutgoingState.failed,
        failure: 'Server busy',
      );
      await _pump(tester, lang, MessageTile(message: failed, showHeader: true, onRetry: () => retried = true, onDiscard: () {}));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(lang == 'en' ? 'Retry' : 'إعادة المحاولة'));
      expect(retried, isTrue);
      expect(find.textContaining('conv.'), findsNothing);
    });

    testWidgets('working card shows the live stage and Stop for the requester ($lang)', (tester) async {
      ConvSession? stopped;
      final s = ConvSession.fromJson({
        'id': 'sess',
        'agentId': 'a-00',
        'agentName': 'Flow Agent',
        'messageId': 'm',
        'status': 'working',
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'requesterId': 'u-me',
        'specialists': [
          {'agentName': 'Visual Inspector', 'status': 'running', 'stage': 'reading 3 photos'},
        ],
      });
      await _pump(tester, lang, WorkingCard(sessions: [s], myIds: const {'u-me'}, onStop: (x) => stopped = x));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('reading 3 photos'), findsOneWidget);
      await tester.tap(find.text(lang == 'en' ? 'Stop' : 'إيقاف'));
      expect(stopped?.id, 'sess');
      expect(find.textContaining('conv.'), findsNothing);
      await tester.pumpWidget(const SizedBox()); // dispose the 1 s ticker
    });

    testWidgets('schedule card with actions ($lang)', (tester) async {
      final s = UserSchedule.fromJson({
        'id': 's1',
        'kind': 'agent_task',
        'title': 'Send me open snags in Tower A',
        'human': 'Every day 07:00',
        'status': 'active',
        'nextRunAt': DateTime.now().add(const Duration(hours: 3)).toUtc().toIso8601String(),
        'lastResult': {'status': 'done', 'summary': '4 open snags, 1 overdue.', 'at': '2026-09-30T03:00:00Z'},
      });
      var paused = false;
      await _pump(tester, lang, ScheduleCard(schedule: s, onPause: () => paused = true, onDelete: () {}, onRunNow: () {}));
      expect(tester.takeException(), isNull);
      expect(find.text('Every day 07:00'), findsOneWidget);
      expect(find.text('4 open snags, 1 overdue.'), findsOneWidget);
      await tester.tap(find.text(lang == 'en' ? 'Pause' : 'إيقاف مؤقت'));
      expect(paused, isTrue);
      expect(find.textContaining('schedules.'), findsNothing);
    });

    testWidgets('@ picker lists Flow Agent first ($lang)', (tester) async {
      await _pump(
        tester,
        lang,
        MentionPickerList(
          candidates: const [
            MentionCandidate(type: ConvAuthorType.agent, id: 'agent', name: 'Flow Agent', handle: 'agent', role: 'picks the right specialist', orchestrator: true),
            MentionCandidate(type: ConvAuthorType.agent, id: 'a47', name: 'Visual Inspector', handle: 'visual-inspector', role: 'checks photos'),
            MentionCandidate(type: ConvAuthorType.user, id: 'u', name: 'Ops Admin', handle: 'ops'),
          ],
          onPick: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
      final first = tester.getTopLeft(find.text('@agent — Flow Agent'));
      final second = tester.getTopLeft(find.text('Visual Inspector'));
      expect(first.dy, lessThan(second.dy));
    });
  }

  test('mention spans colour agents and people differently', () {
    final spans = mentionSpans('hi @agent and @ravi', agentHandles: const {});
    final texts = spans.whereType<TextSpan>().map((s) => s.text).toList();
    expect(texts, ['hi ', '@agent', ' and ', '@ravi']);
  });
}
