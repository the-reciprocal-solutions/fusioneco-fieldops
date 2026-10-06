import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/conversation/next_steps.dart';
import 'package:technician_portal/domain/conversation.dart';
import 'package:technician_portal/features/conversation/widgets/composer.dart';
import 'package:technician_portal/features/conversation/widgets/message_tile.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// 2026-10-06 (owner on an iPhone): replying to an agent now reaches it
/// without typing @agent, and its answer ends with one-tap next steps that
/// only OPEN a screen (server `nextSteps`, services/conversations/nextSteps.ts).

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

final _answer = ConvMessage.fromJson({
  'id': 'r1',
  'author': {'type': 'agent', 'id': 'a-00', 'name': 'Flow Agent'},
  'body': 'The bearing limit is not in the records.\n\n**Next actions**\n1. Measure the bearing temperature.\n2. Isolate the supply before opening the panel.',
  'createdAt': '2026-10-06T08:00:00Z',
  'replyTo': 'm1',
  'nextSteps': [
    {'id': 'open-asset', 'action': 'open_asset', 'label': 'Open the asset', 'target': {'assetId': 'a5'}},
    {
      'id': 'raise-snag',
      'action': 'raise_snag',
      'label': 'Raise a snag',
      'target': {'assetId': 'a5', 'assetName': 'AHU-2', 'assetRef': 'AST007', 'buildingId': 'b1'},
    },
    {'id': 'open-permits', 'action': 'open_permits', 'label': 'Permits', 'target': {}},
    {'id': 'x', 'action': 'approve_card', 'label': 'Approve'}, // unknown → dropped
    {'id': 'y', 'action': 'open_asset', 'label': 'Open', 'target': {}}, // no asset id → dropped
  ],
});

void main() {
  group('next steps (pure)', () {
    test('parse: known actions only, open_asset needs an id, empty target values dropped', () {
      expect(_answer.nextSteps.map((s) => s.action), [
        ConvNextStepAction.openAsset,
        ConvNextStepAction.raiseSnag,
        ConvNextStepAction.openPermits,
      ]);
      expect(_answer.nextSteps[1].target, {'assetId': 'a5', 'assetName': 'AHU-2', 'assetRef': 'AST007', 'buildingId': 'b1'});
      expect(ConvMessage.fromJson({'id': 'z', 'body': 'x'}).nextSteps, isEmpty);
      // copyWith keeps them (the outbox / "mine" path).
      expect(_answer.copyWith(mine: true).nextSteps, hasLength(3));
    });

    test('routes: snag pre-filled, the asset, permits — screens only', () {
      expect(routeForNextStep(_answer.nextSteps[0]), '/asset/a5');
      final snag = Uri.parse(routeForNextStep(_answer.nextSteps[1]));
      expect(snag.path, '/snags/new');
      expect(snag.queryParameters, {'buildingId': 'b1', 'assetId': 'a5', 'assetName': 'AHU-2', 'assetRef': 'AST007'});
      expect(routeForNextStep(_answer.nextSteps[2]), '/permits');
      final fromWo = ConvNextStep.fromJson({'action': 'raise_snag', 'target': {'workOrderId': 'wo-1'}})!;
      expect(Uri.parse(routeForNextStep(fromWo)).queryParameters, {'workOrderId': 'wo-1'});
    });

    test('a reply to an agent message reaches it (when this person may ask agents)', () {
      final person = ConvMessage.fromJson({'id': 'p', 'author': {'type': 'user', 'id': 'u', 'name': 'Ravi'}, 'body': 'x'});
      expect(replyReachesAgent(_answer, canMentionAgents: true), isTrue);
      expect(replyReachesAgent(_answer, canMentionAgents: false), isFalse);
      expect(replyReachesAgent(person, canMentionAgents: true), isFalse);
      expect(replyReachesAgent(null, canMentionAgents: true), isFalse);
    });
  });

  group('widgets', () {
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
      testWidgets('next-step chips under an agent answer open their screen ($lang)', (tester) async {
        ConvNextStep? tapped;
        await _pump(tester, lang, MessageTile(message: _answer, showHeader: true, onNextStep: (s) => tapped = s));
        expect(tester.takeException(), isNull);
        expect(find.text(lang == 'en' ? 'Raise a snag' : 'الإبلاغ عن ملاحظة'), findsOneWidget);
        expect(find.text(lang == 'en' ? 'Open the asset' : 'فتح الأصل'), findsOneWidget);
        expect(find.text(lang == 'en' ? 'Permits' : 'التصاريح'), findsOneWidget);
        expect(find.textContaining('conv.'), findsNothing, reason: 'a raw i18n key leaked');
        await tester.tap(find.byKey(const ValueKey('next-step-raise-snag')));
        expect(tapped?.action, ConvNextStepAction.raiseSnag);
      });

      testWidgets('replying to the agent says it will answer — no "add @agent" nudge ($lang)', (tester) async {
        await _pump(
          tester,
          lang,
          ConversationComposer(
            canMentionAgents: true,
            replyingTo: _answer,
            onSend: (_) async {},
            searchMentions: (_) async => const [],
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.textContaining(lang == 'en' ? 'it will answer' : 'سيجيب'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'remind me tomorrow at 9');
        await tester.pump();
        // The schedule hint, not "add @agent so it sets this up".
        expect(find.text('conv.hint_add_agent_action'.getString(tester.element(find.byType(ConversationComposer)))), findsNothing);
        expect(find.textContaining('conv.'), findsNothing);
      });
    }
  });
}
