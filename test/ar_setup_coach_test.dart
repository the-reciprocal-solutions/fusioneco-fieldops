import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/ar/ar_engine.dart' show ArTracking;
import 'package:technician_portal/features/ar/setup/ar_setup_coach.dart';
import 'package:technician_portal/features/ar/widgets/ar_sunlight.dart';
import 'package:technician_portal/state/ar_setup_controller.dart';
import 'package:technician_portal/theme/app_theme.dart';

/// The setup coach (owner, 2026-10-06): one instruction at a time, the
/// reason and the next step for every failure. Pure state machine first,
/// then the strip and the guide rendered at phone size in EN and AR.

Map<String, dynamic> _strings(String lang) =>
    jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;

SetupCue cue(ArSetupStep step, {
  String tracking = ArTracking.tracking,
  String? reason,
  int? scan,
  bool snapped = false,
  String? snappedShape,
  ArCornerProblem? problem,
  String? problemShape,
  bool wallsMissing = false,
  bool tooCloseB = false,
  bool noMatchB = false,
  bool matchedB = false,
  bool ambiguousB = false,
  bool wantsBaseline = false,
  String targetKind = 'inside',
  int? secondPin,
  double? bearing,
  double? dist,
  Duration aiming = Duration.zero,
}) =>
    setupCueFor(SetupCoachInputs(
      step: step,
      tracking: tracking,
      trackingReason: reason,
      scanPercent: scan,
      snapped: snapped,
      snappedShape: snappedShape,
      snappedAngle: snapped ? 93 : null,
      problem: problem,
      problemShape: problemShape,
      wallsMissing: wallsMissing,
      tooCloseB: tooCloseB,
      noMatchB: noMatchB,
      matchedB: matchedB,
      ambiguousB: ambiguousB,
      wantsBaseline: wantsBaseline,
      targetPin: 2,
      targetKind: targetKind,
      secondPin: secondPin,
      secondBearingDeg: bearing,
      secondDistanceM: dist,
      aimingFor: aiming,
    ));

void main() {
  group('setupCueFor — each step gives the right instruction', () {
    test('before start: pick on the plan, guide step 1', () {
      final c = cue(ArSetupStep.start);
      expect(c.key, 'ar.coach.cue.pick');
      expect(c.args, [2]);
      expect(c.guideStep, 0);
    });

    test('scanning below 60%: sweep, with the percentage and a bar', () {
      final c = cue(ArSetupStep.cornerA, scan: 45);
      expect(c.key, 'ar.coach.cue.scan');
      expect(c.args, [45]);
      expect(c.progress, closeTo(0.45, 1e-9));
      expect(c.guideStep, 1);
    });

    test('scanned: walk to the highlighted corner, then aim where the walls meet', () {
      expect(cue(ArSetupStep.cornerA, scan: 80).key, 'ar.coach.cue.walk_inside');
      expect(cue(ArSetupStep.cornerA, scan: 80, targetKind: 'column').key, 'ar.coach.cue.walk_column');
      expect(cue(ArSetupStep.cornerA, scan: 80, aiming: const Duration(seconds: 7)).key, 'ar.coach.cue.aim_inside');
    });

    test('snapped: tap Use this corner (success tone)', () {
      final c = cue(ArSetupStep.cornerA, scan: 30, snapped: true, snappedShape: 'inside');
      expect(c.key, 'ar.coach.cue.snapped_inside');
      expect(c.args, [93]);
      expect(c.tone, SetupCueTone.success);
    });

    test('every failure has its own reason and next step', () {
      expect(cue(ArSetupStep.cornerA, snapped: true, problem: ArCornerProblem.otherShapeNearby, problemShape: 'inside').key,
          'ar.coach.cue.shape_inside');
      expect(cue(ArSetupStep.cornerA, problem: ArCornerProblem.otherShapeNearby, problemShape: 'outside').key,
          'ar.coach.cue.shape_outside');
      expect(cue(ArSetupStep.cornerA, problem: ArCornerProblem.noneOfShape, problemShape: 'inside').key, 'ar.coach.cue.wrong_model');
      expect(cue(ArSetupStep.cornerA, problem: ArCornerProblem.notPlaced).key, 'ar.coach.cue.not_placed');
      final walls = cue(ArSetupStep.cornerA, wallsMissing: true, scan: 80);
      expect(walls.key, 'ar.coach.cue.no_walls');
      expect(walls.action, SetupCueAction.wallTaps);
      expect(cue(ArSetupStep.cornerB, matchedB: true, tooCloseB: true).key, 'ar.coach.cue.too_close');
      expect(cue(ArSetupStep.cornerB, noMatchB: true, secondPin: 4).args, [4]);
      final mismatch = cue(ArSetupStep.mismatch);
      expect(mismatch.key, 'ar.coach.cue.mismatch');
      expect(mismatch.action, SetupCueAction.realign);
      for (final c in [
        cue(ArSetupStep.cornerA, problem: ArCornerProblem.noneOfShape, problemShape: 'inside'),
        cue(ArSetupStep.cornerB, noMatchB: true),
        mismatch,
      ]) {
        expect(c.tone, SetupCueTone.warning);
      }
    });

    test('tracking first: too dark, too fast, plain walls, lost, starting', () {
      expect(cue(ArSetupStep.cornerA, tracking: ArTracking.limited, reason: 'insufficientLight', snapped: true).key, 'ar.coach.cue.too_dark');
      expect(cue(ArSetupStep.cornerA, tracking: ArTracking.limited, reason: 'excessiveMotion').key, 'ar.coach.cue.too_fast');
      expect(cue(ArSetupStep.cornerB, tracking: ArTracking.limited, reason: 'insufficientFeatures').key, 'ar.coach.cue.plain_walls');
      expect(cue(ArSetupStep.cornerA, tracking: ArTracking.limited, reason: 'relocalizing').key, 'ar.coach.cue.tracking_lost');
      expect(cue(ArSetupStep.start, tracking: ArTracking.initializing).key, 'ar.coach.cue.starting');
    });

    test('corner 2: 3 m+ away, with a direction arrow once the pose is known', () {
      expect(cue(ArSetupStep.cornerB, secondPin: 3).key, 'ar.coach.cue.second');
      final c = cue(ArSetupStep.cornerB, secondPin: 3, bearing: -40, dist: 4.24);
      expect(c.key, 'ar.coach.cue.second_dir');
      expect(c.args, [3, '4.2']);
      expect(c.arrowDeg, -40);
      expect(cue(ArSetupStep.cornerB, matchedB: true).key, 'ar.coach.cue.b_found');
      expect(cue(ArSetupStep.cornerB, ambiguousB: true).key, 'ar.coach.cue.which');
      expect(cue(ArSetupStep.cornerB, wantsBaseline: true).key, 'ar.coach.cue.baseline');
    });

    test('success: model placed, walk around, with Re-align', () {
      for (final step in [ArSetupStep.locked, ArSetupStep.aligned]) {
        final c = cue(step);
        expect(c.key, 'ar.coach.cue.placed');
        expect(c.action, SetupCueAction.realign);
        expect(c.tone, SetupCueTone.success);
      }
    });

    test('every step has a cue whose key exists in EN and AR', () {
      final en = _strings('en'), ar = _strings('ar');
      for (final step in ArSetupStep.values) {
        final k = cue(step).key;
        expect(en.containsKey(k) && ar.containsKey(k), isTrue, reason: '$step → $k');
      }
    });
  });

  group('the strip and the guide at phone size', () {
    setUpAll(() async {
      SharedPreferences.setMockInitialValues({});
      final l = FlutterLocalization.instance;
      await l.ensureInitialized();
      l.init(
        mapLocales: [MapLocale('en', _strings('en')), MapLocale('ar', _strings('ar'))],
        initLanguageCode: 'en',
      );
    });

    Widget host(String lang, Widget child, {bool sunlight = false}) => ProviderScope(
          child: MaterialApp(
            theme: AppTheme.build(),
            supportedLocales: FlutterLocalization.instance.supportedLocales,
            localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
            locale: Locale(lang),
            home: Scaffold(
              backgroundColor: Colors.black,
              body: ArSunlightScope(
                on: sunlight,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(padding: const EdgeInsets.all(16), child: child),
                ),
              ),
            ),
          ),
        );

    for (final lang in ['en', 'ar']) {
      for (final sunlight in [false, true]) {
        testWidgets('scan cue with bar, notice and help — 320 px, $lang${sunlight ? ', sunlight' : ''}', (tester) async {
          FlutterLocalization.instance.translate(lang);
          tester.view.physicalSize = const Size(320, 640) * 2;
          tester.view.devicePixelRatio = 2;
          addTearDown(tester.view.reset);
          var help = 0;
          await tester.pumpWidget(host(
            lang,
            ArCoachStripView(
              cue: cue(ArSetupStep.cornerA, scan: 60 - 15),
              detail: '#2 · Column · NW corner',
              onHelp: () => help++,
            ),
            sunlight: sunlight,
          ));
          await tester.pump();
          expect(tester.takeException(), isNull);
          final expected = _strings(lang)['ar.coach.cue.scan'] as String;
          final text = tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('ar-coach-text')), matching: find.byType(Text)));
          expect(text.data, expected.replaceFirst('%a', '45'));
          expect(find.byType(LinearProgressIndicator), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('ar-coach-help')));
          expect(help, 1);
        });
      }
    }

    testWidgets('placed: the Re-align action is offered and works', (tester) async {
      FlutterLocalization.instance.translate('en');
      var realign = 0;
      await tester.pumpWidget(host('en', ArCoachStripView(cue: cue(ArSetupStep.locked), onAction: () => realign++)));
      await tester.pump();
      expect(find.text('Looks off? Re-align'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ar-coach-action')));
      expect(realign, 1);
    });

    testWidgets('corner 2 arrow points the way (not mirrored in Arabic)', (tester) async {
      FlutterLocalization.instance.translate('ar');
      await tester.pumpWidget(host('ar', ArCoachStripView(cue: cue(ArSetupStep.cornerB, secondPin: 3, bearing: 90, dist: 5))));
      await tester.pump();
      final t = tester.widget<Transform>(find.byKey(const ValueKey('ar-coach-arrow')));
      // 90° to the right: a quarter turn clockwise.
      expect(t.transform.storage[1], closeTo(1, 1e-9));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the three-step guide marks the current step and offers "Don\'t show again"', (tester) async {
      FlutterLocalization.instance.translate('en');
      tester.view.physicalSize = const Size(320, 640) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host('en', const SizedBox(height: 600, child: ArSetupGuide(highlight: 1, offerDontShow: true))));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Stand inside the room you opened'), findsOneWidget);
      expect(find.text('Scan slowly until surfaces fill'), findsOneWidget);
      expect(find.text('Point at a corner shown on the plan'), findsOneWidget);
      expect(find.byKey(const ValueKey('ar-guide-dont-show')), findsOneWidget);
    });
  });
}
