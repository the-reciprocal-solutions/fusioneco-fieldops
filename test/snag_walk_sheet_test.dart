import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/domain/snag.dart';
import 'package:technician_portal/domain/snag_ai.dart';
import 'package:technician_portal/features/snags/widgets/snag_walk_sheet.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// Walk mode's details sheet (redesign 2026-10-06) on the smallest iPhone
/// (SE 1st gen, 320×568 pt), with and without the keyboard, in English and
/// Arabic: nothing overflows, Save & next is always on screen, and the photo
/// area above the sheet's lowest height stays free.
Map<String, dynamic> _strings(String lang) {
  final all = jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;
  return {for (final e in all.entries) if (e.key.startsWith('snags.') || e.key.startsWith('common.')) e.key: e.value};
}

const _ai = SnagAiResult(
  status: SnagAiStatus.ok,
  title: 'Socket faceplate cracked next to the door frame',
  trade: 'electrical',
  priority: SnagPriority.major,
  issueType: 'damage',
  captureTips: ['add_wide_shot'],
);

void main() {
  group('SnagWalkSheetSizes', () {
    for (final h in [300.0, 332.0, 548.0, 568.0, 812.0, 1180.0]) {
      test('valid resting sizes at ${h.toInt()} pt', () {
        final s = SnagWalkSheetSizes.forHeight(h);
        expect(s.peek, lessThan(s.collapsed));
        expect(s.collapsed, lessThan(s.max));
        expect(s.max, lessThanOrEqualTo(1));
        expect(s.peek, greaterThan(0));
      });
    }

    test('at peek, an SE keeps most of the screen for the photo', () {
      final s = SnagWalkSheetSizes.forHeight(548); // 568 minus the status bar
      expect(s.peek * 548, closeTo(SnagWalkSheetSizes.peekPx, 0.5));
      expect(1 - s.peek, greaterThan(0.7));
    });
  });

  group('SnagWalkComposeSheet at 320 pt', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      final l = FlutterLocalization.instance;
      await l.ensureInitialized();
      l.init(mapLocales: [MapLocale('en', _strings('en')), MapLocale('ar', _strings('ar'))], initLanguageCode: 'en');
    });

    Future<({DraggableScrollableController sheet, List<String> taps})> pump(
      WidgetTester tester,
      String lang, {
      double keyboard = 0,
    }) async {
      FlutterLocalization.instance.translate(lang);
      tester.view.physicalSize = const Size(320 * 2, 568 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final sheet = DraggableScrollableController();
      addTearDown(sheet.dispose);
      final title = TextEditingController();
      addTearDown(title.dispose);
      final taps = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          supportedLocales: FlutterLocalization.instance.supportedLocales,
          localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
          locale: Locale(lang),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: LayoutBuilder(
              builder: (context, c) {
                final sizes = SnagWalkSheetSizes.forHeight(c.maxHeight);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(key: ValueKey('photo'), color: Colors.blueGrey),
                    SnagWalkComposeSheet(
                      sizes: sizes,
                      controller: sheet,
                      aiRunning: false,
                      ai: _ai,
                      onApplyAllAi: () => taps.add('apply'),
                      onRetryAi: () {},
                      trade: 'finishes',
                      tradeOrder: kSnagTrades,
                      onTrade: (_) {},
                      priority: SnagPriority.minor,
                      onPriority: (_) {},
                      issueType: 'defect',
                      onIssueType: (_) {},
                      title: title,
                      description: 'Hairline crack across the faceplate.',
                      saving: false,
                      onSave: () => taps.add('save'),
                      onMarkUp: () {},
                      onVoice: () {},
                      onSuggest: () {},
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (sheet: sheet, taps: taps);
    }

    void expectOnScreen(WidgetTester tester, Finder f) {
      final r = tester.getRect(f);
      final screen = Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(screen.contains(r.topLeft) && screen.contains(r.bottomRight - const Offset(0.01, 0.01)), isTrue,
          reason: '$r is off screen $screen');
    }

    for (final lang in ['en', 'ar']) {
      testWidgets('collapsed: AI, trade, severity and Save fit, nothing overflows ($lang)', (tester) async {
        final rig = await pump(tester, lang);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('snags.'), findsNothing, reason: 'a raw i18n key leaked');
        expectOnScreen(tester, find.byKey(const ValueKey('snag-walk-save')));
        expectOnScreen(tester, find.byKey(const ValueKey('snag-walk-apply-all')));
        expectOnScreen(tester, find.byKey(const ValueKey('snag-walk-more')));
        await tester.tap(find.byKey(const ValueKey('snag-walk-save')));
        await tester.tap(find.byKey(const ValueKey('snag-walk-apply-all')));
        expect(rig.taps, ['save', 'apply']);
        // The sheet leaves the top of the photo free even when collapsed.
        expect(rig.sheet.size, lessThan(0.6));
      });

      testWidgets('drag down to peek: Save stays, most of the photo shows ($lang)', (tester) async {
        final rig = await pump(tester, lang);
        rig.sheet.jumpTo(SnagWalkSheetSizes.forHeight(568).peek);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectOnScreen(tester, find.byKey(const ValueKey('snag-walk-save')));
        expectOnScreen(tester, find.byKey(const ValueKey('snag-walk-more')));
        expect(rig.sheet.size * 568, lessThan(170));
      });

      testWidgets('More details, then the keyboard up: no overflow, Save still on screen ($lang)', (tester) async {
        await pump(tester, lang);
        await tester.tap(find.byKey(const ValueKey('snag-walk-more')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(TextField), findsOneWidget);
        // The title field is what brings the keyboard up.
        tester.view.viewInsets = const FakeViewPadding(bottom: 216 * 2);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(TextField, skipOffstage: false), findsOneWidget);
        expectOnScreen(tester, find.byKey(const ValueKey('snag-walk-save')));
        final save = tester.getRect(find.byKey(const ValueKey('snag-walk-save')));
        expect(save.bottom, lessThanOrEqualTo(568 - 216 + 0.01), reason: 'above the keyboard');
      });
    }
  });
}
