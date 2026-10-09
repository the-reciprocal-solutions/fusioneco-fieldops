import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/domain/day_brief.dart';
import 'package:technician_portal/features/dashboard/widgets/day_brief_card.dart';
import 'package:technician_portal/features/dashboard/widgets/process_guides_sheet.dart';
import 'package:technician_portal/state/day_brief_controller.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// The Your day card in every state, at phone size (360×780), in English and
/// Arabic, with the real string files — so a missing key or an overflow in
/// either language fails here, not on a technician's phone.
final _now = DateTime(2026, 10, 10, 10, 5);

DayStep _step(int order, String id, {String kind = 'wo', bool done = false, String code = 'due_today', TextSource src = TextSource.rules, String reason = '', DayPermit? permit, List<DayItem> items = const [], bool overdue = false, bool safety = false}) =>
    DayStep(
      order: order,
      kind: kind,
      id: id,
      ref: 'WO-$order',
      title: 'Chiller 2 tripping on overload — replace the 32A contactor on level B1',
      location: 'Fusion Eco Tower A · Basement',
      due: DateTime(2026, 10, 10, 15),
      done: done,
      reasonCode: code,
      reasonSource: src,
      reason: reason,
      permit: permit,
      permitBlocked: permit?.blocking ?? false,
      overdue: overdue,
      safety: safety,
      items: items,
      route: kind == 'invite' ? '/technician/invites' : '/technician/orders/work-order/$id',
    );

final _items = [
  const DayItem(code: 'parts_listed', params: {'parts': '2× Contactor 32A'}, text: ''),
  const DayItem(code: 'checklist', params: {'done': '0', 'total': '3'}, text: ''),
  const DayItem(code: 'access', params: {'note': 'Collect the plant room keys from the security desk.'}, text: ''),
  const DayItem(code: 'ai_tip', text: 'Isolate the supply at DB-3 before fitting', source: TextSource.ai),
];

final _aiBrief = DayBrief(
  summary: 'Start with the smoke smell near the DB room as it is safety-critical. Then the chiller and AHU jobs on the same basement floor.',
  summarySource: TextSource.ai,
  aiAvailable: true,
  generatedAt: DateTime(2026, 10, 10, 10, 0),
  steps: [
    _step(1, 'w1', code: 'safety', safety: true, src: TextSource.ai, reason: 'Safety-critical smell — check it first.',
        permit: const DayPermit(state: 'suggested', type: 'electrical', typeLabel: 'Electrical / LOTO'), items: _items),
    _step(2, 'w2', code: 'overdue', overdue: true, items: _items),
    _step(3, 'w3'),
    _step(4, 'w4', kind: 'invite', code: 'invite'),
    _step(5, 'w5', done: true, code: 'done'),
    _step(6, 'w6'),
  ],
);

DayBriefState _state(String which) => switch (which) {
      'loading' => DayBriefState(phase: DayBriefPhase.loading, steps: _aiBrief.steps.take(3).toList()),
      'ai' => DayBriefState(phase: DayBriefPhase.ready, brief: _aiBrief, steps: _aiBrief.steps),
      'offline' => DayBriefState(phase: DayBriefPhase.offline, brief: _aiBrief, savedAt: DateTime(2026, 10, 10, 7, 30), steps: _aiBrief.steps.take(3).toList()),
      'empty' => DayBriefState(phase: DayBriefPhase.ready, brief: DayBrief(summary: '', generatedAt: _now), steps: const []),
      'error' => DayBriefState(phase: DayBriefPhase.error, steps: _aiBrief.steps.skip(1).take(2).toList()),
      _ => throw ArgumentError(which),
    };

Map<String, dynamic> _load(String lang) => jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;

final opened = <String>[];
var guidesOpened = 0;

Future<void> _pump(WidgetTester tester, String which, String lang) async {
  tester.view.physicalSize = const Size(360, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  FlutterLocalization.instance.translate(lang);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(),
      locale: Locale(lang),
      supportedLocales: const [Locale('en'), Locale('ar')],
      localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
      home: Directionality(
        textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: DayBriefView(
              state: _state(which),
              now: _now,
              tick: false,
              onRefresh: () async {},
              onOpenRoute: opened.add,
              onOpenGuides: () => guidesOpened++,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final l = FlutterLocalization.instance;
    await l.ensureInitialized();
    l.init(mapLocales: [MapLocale('en', _load('en')), MapLocale('ar', _load('ar'))], initLanguageCode: 'en');
  });

  setUp(() {
    opened.clear();
    guidesOpened = 0;
  });

  for (final lang in ['en', 'ar']) {
    group('[$lang]', () {
      for (final which in ['loading', 'ai', 'offline', 'empty', 'error']) {
        testWidgets('$which renders at phone size without overflow', (tester) async {
          await _pump(tester, which, lang);
          expect(tester.takeException(), isNull);
          expect(find.text('day.title'.getString(tester.element(find.byType(DayBriefView)))), findsOneWidget);
          // Guides are always one tap away.
          expect(find.byKey(const Key('day-guides')), findsOneWidget);
        });
      }

      testWidgets('loading: shimmer while the first brief comes, phone plan already listed', (tester) async {
        await _pump(tester, 'loading', lang);
        expect(find.byKey(const Key('day-brief-shimmer')), findsOneWidget);
        expect(find.byKey(const Key('day-step-w1')), findsOneWidget);
      });

      testWidgets('AI: sparkle summary, ordered steps, a done tick, permit tip, start next', (tester) async {
        await _pump(tester, 'ai', lang);
        expect(find.byKey(const Key('day-ai-summary')), findsOneWidget);
        expect(find.textContaining('Start with the smoke smell'), findsOneWidget);
        expect(find.byKey(const Key('day-permit-tip')), findsOneWidget);
        // 6 steps, 5 shown, the rest behind "Show all".
        expect(find.byKey(const Key('day-step-w6')), findsNothing);
        await tester.ensureVisible(find.byKey(const Key('day-start-next')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('day-start-next')));
        expect(opened, ['/technician/orders/work-order/w1']);
      });

      testWidgets('Before you go expands with rules items and the AI tip', (tester) async {
        await _pump(tester, 'ai', lang);
        await tester.tap(find.byKey(const Key('day-expand-w2')));
        await tester.pump();
        expect(find.textContaining('2× Contactor 32A'), findsOneWidget);
        expect(find.textContaining('Isolate the supply at DB-3'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('offline: Saved earlier label + no-signal note', (tester) async {
        await _pump(tester, 'offline', lang);
        final ctx = tester.element(find.byType(DayBriefView));
        expect(find.text(ctx.formatString('day.saved_earlier'.getString(ctx), ['07:30'])), findsOneWidget);
        expect(find.text('day.offline_plan'.getString(ctx)), findsOneWidget);
      });

      testWidgets('error: plain message, rules summary from the steps', (tester) async {
        await _pump(tester, 'error', lang);
        final ctx = tester.element(find.byType(DayBriefView));
        expect(find.text('day.error_plan'.getString(ctx)), findsOneWidget);
        expect(find.byKey(const Key('day-rules-summary')), findsOneWidget);
        expect(find.byKey(const Key('day-ai-summary')), findsNothing);
      });

      testWidgets('empty: says so, still offers the guides', (tester) async {
        await _pump(tester, 'empty', lang);
        expect(find.byKey(const Key('day-empty')), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('day-guides')));
        await tester.tap(find.byKey(const Key('day-guides')));
        expect(guidesOpened, 1);
      });

      testWidgets('guides list renders and opens a screen / asks AI', (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        FlutterLocalization.instance.translate(lang);
        final asked = <String>[];
        final routes = <String>[];
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.build(),
          home: Directionality(
            textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(body: ProcessGuidesList(nextJobId: 'w1', onOpen: routes.add, onAskAi: asked.add)),
          ),
        ));
        await tester.tap(find.byKey(const Key('guide-work_order')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('guide-open-work_order')));
        await tester.tap(find.byKey(const Key('guide-ask-work_order')));
        expect(routes, ['/orders/work-order/w1']);
        expect(asked.single, isNotEmpty);
      });
    });
  }
}
