import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/domain/conversation.dart';
import 'package:technician_portal/features/conversation/widgets/composer.dart';
import 'package:technician_portal/features/conversation/widgets/message_tile.dart';
import 'package:technician_portal/features/conversation/widgets/working_card.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// 2026-10-06 owner round: the keyboard can be closed, the agent's work is
/// visible step by step, and failures read in plain words — on a 320 pt
/// phone, English and Arabic.
Map<String, dynamic> _strings(String lang) {
  final all = jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in all.entries)
      if (e.key.startsWith('conv.') || e.key.startsWith('schedules.') || e.key.startsWith('common.')) e.key: e.value,
  };
}

Future<void> _pump(WidgetTester tester, String lang, Widget child, {bool scroll = true, double height = 780}) async {
  FlutterLocalization.instance.translate(lang);
  tester.view.physicalSize = Size(320 * 3, height * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.build(),
        supportedLocales: FlutterLocalization.instance.supportedLocales,
        localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
        locale: Locale(lang),
        home: Scaffold(body: scroll ? SingleChildScrollView(child: child) : child),
      ),
    ),
  );
  await tester.pump();
}

ConvSession _session(String status, {Duration ago = const Duration(seconds: 20), String? stage}) => ConvSession.fromJson({
  'id': 'sess',
  'agentId': 'a-00',
  'agentName': 'Flow Agent',
  'messageId': 'm',
  'status': status,
  'stage': ?stage,
  'elapsedMs': ago.inMilliseconds,
  'startedAt': DateTime.now().subtract(ago).toUtc().toIso8601String(),
  'requesterId': 'u-me',
  'routing': {'rule': 'keywords', 'agents': [{'templateId': 'A47', 'name': 'Visual Inspector', 'reason': 'photos'}]},
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
    testWidgets('composer: a hide-keyboard button appears while typing and closes the keyboard ($lang)', (tester) async {
      await _pump(
        tester,
        lang,
        Column(
          children: [
            const Expanded(child: SizedBox()),
            ConversationComposer(
              canMentionAgents: true,
              onSend: (_) async {},
              searchMentions: (_) async => const [],
            ),
          ],
        ),
        scroll: false,
      );
      final hide = find.byKey(const ValueKey('conv-hide-keyboard'));
      expect(hide, findsNothing, reason: 'no button while the box is not focused');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      expect(hide, findsOneWidget);
      await tester.tap(hide);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse, reason: 'the keyboard must close');
      expect(hide, findsNothing);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('conv.'), findsNothing);
    });

    testWidgets('thinking bubble shows the real steps, newest live ($lang)', (tester) async {
      await _pump(
        tester,
        lang,
        AgentThinkingBubble(
          session: _session('working', stage: 'thinking it through'),
          steps: const ['reading the record', 'Visual Inspector · checking photos'],
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text(lang == 'en' ? 'Flow Agent is thinking' : 'Flow Agent يفكر'), findsOneWidget);
      expect(find.text('Reading the record'), findsOneWidget);
      expect(find.text('Visual Inspector · checking photos'), findsOneWidget);
      expect(find.text('Thinking it through'), findsOneWidget, reason: 'the live stage is the newest step');
      expect(find.byType(TypingDots), findsOneWidget);
      expect(find.textContaining('conv.'), findsNothing);
      await tester.pumpWidget(const SizedBox()); // stop the dots
    });

    testWidgets('queued for minutes → says it is still waiting, plainly ($lang)', (tester) async {
      await _pump(tester, lang, AgentThinkingBubble(session: _session('queued', ago: const Duration(minutes: 4))));
      expect(tester.takeException(), isNull);
      expect(find.textContaining(lang == 'en' ? 'Still waiting to start' : 'ما زال ينتظر البدء'), findsOneWidget);
      expect(find.textContaining('conv.'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('compact working card fits one line with Stop ($lang)', (tester) async {
      ConvSession? stopped;
      await _pump(
        tester,
        lang,
        WorkingCard(sessions: [_session('working', stage: 'checking photos')], myIds: const {'u-me'}, compact: true, onStop: (s) => stopped = s),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Visual Inspector'), findsNothing, reason: 'routing is left to the full card');
      await tester.tap(find.text(lang == 'en' ? 'Stop' : 'إيقاف'));
      expect(stopped?.id, 'sess');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed post reads in plain words, never the raw server text ($lang)', (tester) async {
      final m = ConvMessage(
        id: 'local:c1',
        author: const ConvAuthor(type: ConvAuthorType.user, id: 'u-me', name: 'Ravi'),
        body: '@agent remind me tomorrow at 9',
        createdAt: DateTime.now(),
        clientId: 'c1',
        mine: true,
        outgoing: OutgoingState.failed,
        failure: 'conv.err_location',
      );
      await _pump(tester, lang, MessageTile(message: m, showHeader: true, onRetry: () {}, onDiscard: () {}));
      expect(tester.takeException(), isNull);
      expect(find.textContaining(lang == 'en' ? 'Check in your location first' : 'سجّل موقعك أولاً'), findsOneWidget);
      expect(find.textContaining('/fm/technicians'), findsNothing);
      expect(find.textContaining('conv.'), findsNothing);
    });
  }
}
