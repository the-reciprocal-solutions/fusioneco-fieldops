import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:technician_portal/core/ar/alignment_estimator.dart';
import 'package:technician_portal/core/ar/ar_engine.dart' show ArTracking;
import 'package:technician_portal/core/ar/corner_matcher.dart';
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/core/offline/offline_db.dart' show ArPackStore;
import 'package:technician_portal/features/ar/setup/ar_setup_overlay.dart';
import 'package:technician_portal/features/ar/widgets/ar_mini_plan.dart';
import 'package:technician_portal/state/ar_prefs_controller.dart' show ArPlaceMethod;
import 'package:technician_portal/state/ar_session_controller.dart';
import 'package:technician_portal/state/ar_setup_controller.dart';
import 'package:technician_portal/state/ar_view_models.dart';
import 'package:technician_portal/state/providers.dart' show arPackStoreProvider;
import 'package:technician_portal/theme/app_theme.dart';

/// Corner A on a real iPhone (2026-10-06): the owner stood in their bedroom
/// with the STTCC data-centre floor open, snapped an inside corner at 93°
/// ("Snapped · inside corner, 93° · walls") with "#2 · Column · NW corner"
/// picked, and got "That corner didn't place the model. Try another one." on
/// every tap. These tests rebuild that situation and the bedroom case where
/// the model does match.

// ------------------------------------------------------------- fixtures

CornerCandidate _c(String id, double x, double z, List<double> a, List<double> b, String kind, double rank, String label) =>
    CornerCandidate(
      id: id,
      posTile: Vec3(x, 0, z),
      faceA: Vec2(a[0], a[1]),
      faceB: Vec2(b[0], b[1]),
      angleDeg: 90,
      kind: kind,
      structural: kind == 'column',
      rank: rank,
      label: label,
    );

/// The bedroom's corners exactly as the server extracted them from
/// `FusionEco_Demo_Bedroom.ifc` (3.048 × 4.877 m, 230 mm walls and columns;
/// rows from `bim_ar_corners`, dev DB, 2026-10-06): 3 inside corners (the
/// fourth is cut short by the door) and the columns' outer corners.
final bedroom = [
  _c('col-nw', 0, -5.337, [0, -1], [-1, 0], 'column', 0.9, 'Column · NW corner'),
  _c('col-sw', 0, 0, [-1, 0], [0, 1], 'column', 0.9, 'Column · SW corner'),
  _c('col-se', 3.508, 0, [0, 1], [1, 0], 'column', 0.9, 'Column · SE corner'),
  _c('in-nw', 0.23, -5.107, [0, 1], [1, 0], 'inside', 0.75, 'Bedroom 1 · NW corner'),
  _c('in-sw', 0.23, -0.23, [1, 0], [0, -1], 'inside', 0.35, 'Bedroom 1 · SW corner'),
  _c('in-se', 3.278, -0.23, [0, -1], [-1, 0], 'inside', 0.35, 'Bedroom 1 · SE corner'),
];

/// An STTCC-like data-hall floor: a 4 × 3 column grid at 7.2 m, 0.6 m
/// columns, four outside corners each, no walls standing on the floor —
/// so the extractor finds column corners only, all labelled
/// "Column · NW corner" and so on (no grid crossing or room within reach).
List<CornerCandidate> sttcc({bool withFarRoom = false}) {
  final out = <CornerCandidate>[];
  const dirs = {
    'NW': ([0.0, -1.0], [-1.0, 0.0], 0.0, 0.0),
    'NE': ([1.0, 0.0], [0.0, -1.0], 0.6, 0.0),
    'SE': ([0.0, 1.0], [1.0, 0.0], 0.6, 0.6),
    'SW': ([-1.0, 0.0], [0.0, 1.0], 0.0, 0.6),
  };
  var n = 0;
  for (var i = 0; i < 4; i++) {
    for (var j = 0; j < 3; j++) {
      for (final e in dirs.entries) {
        final (a, b, dx, dz) = e.value;
        n++;
        out.add(_c('col$n', i * 7.2 + dx, -j * 7.2 - dz, a, b, 'column', 0.9, 'Column · ${e.key} corner${n > 4 ? ' ($n)' : ''}'));
      }
    }
  }
  if (withFarRoom) {
    out.add(_c('office', 60, -30, [0, 1], [1, 0], 'inside', 0.6, 'Office · NW corner'));
  }
  return out;
}

final _yaw = degToRad(30);
final _truth = Mat4.fromYawTranslation(_yaw, const Vec3(1, 0, -3));

/// What the phone reports at model corner [c]: an inside corner snapped
/// from tracked planes, 3° out of square.
DetectedCorner snapAt(CornerCandidate c, {double angle = 93, String method = 'planes', String kind = 'inside'}) =>
    DetectedCorner(
      posAr: _truth.transformPoint(c.posTile),
      faceAAr: rotateXz(c.faceA, _yaw),
      faceBAr: rotateXz(c.faceB, _yaw),
      angleDeg: angle,
      kind: kind,
      method: method,
    );

/// An inside-corner snap somewhere in a room that isn't in the model.
const roomSnap = DetectedCorner(
  posAr: Vec3(2, 0, -1),
  faceAAr: Vec2(0, 1),
  faceBAr: Vec2(1, 0),
  angleDeg: 93,
  kind: 'inside',
  method: 'planes',
);

// ------------------------------------------------------------------ fakes

/// The session as the setup controller sees it: running, a floor, no
/// engine. Observations are fitted with the real estimator; toasts are kept.
class _Session extends ArSessionController {
  _Session(this.initial);
  final ArSessionState initial;
  final toasts = <(String, List<Object>)>[];
  final _estimator = const AlignmentEstimator();

  @override
  ArSessionState build() => initial;

  @override
  void toast(String key, {List<Object> args = const [], ArToastTone tone = ArToastTone.info}) {
    toasts.add((key, args));
    super.toast(key, args: args, tone: tone);
  }

  @override
  AlignmentFit addObservation(ArObservation o, {String? anchorId}) {
    final obs = [for (final x in state.observations) if (x.id != o.id) x, o];
    final fit = _estimator.fit(obs);
    state = state.copyWith(observations: obs, fit: fit);
    return fit;
  }

  @override
  Future<void> anchorObservation(ArObservation o) async {}

  @override
  Future<DetectedCorner?> detectCornerAt(double x, double y) async => null;

  @override
  Future<void> setPins(List<ArPinSpec> pins) async {}
}

class _PrefStore implements ArPackStore {
  _PrefStore(this.prefs);
  final Map<String, String> prefs;

  @override
  Future<String?> getArPref(String key) async => prefs[key];

  @override
  Future<void> setArPref(String key, String? value) async {
    if (value == null) {
      prefs.remove(key);
    } else {
      prefs[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

Map<String, dynamic> _strings(String lang) =>
    jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map<String, dynamic>;

ArFloorContext _floor(List<CornerCandidate> corners) => ArFloorContext(
  buildingId: 'b1',
  buildingName: 'Demo',
  floorId: 'f1',
  floorName: '00',
  builds: const [],
  tiles: const [],
  markers: const [],
  corners: corners,
  gridLines: const [],
);

// ------------------------------------------------------------------ tests

void main() {
  const matcher = CornerMatcher();

  group('root cause — the pre-fix rule on the owner\'s screen', () {
    test('a 93° snap is NOT the problem: it is within tolerance of a 90° corner', () {
      expect(matcher.shapeMatches(snapAt(bedroom[3]), bedroom[3]), isTrue);
    });

    test('STTCC short list: inside-first ranking still holds only column corners, so the old fallback '
        '(first shape match in `ranked`) found nothing and fired corner_rejected', () {
      final ranked = matcher.rankForRoom(sttcc());
      final insideFirst = [...ranked.where((c) => c.kind == 'inside'), ...ranked.where((c) => c.kind != 'inside')];
      // "#2 · Column · NW corner": pin 2 is a column, so pin 1 is too.
      expect(insideFirst.take(2).every((c) => c.kind == 'column'), isTrue);
      expect(insideFirst.any((c) => matcher.shapeMatches(roomSnap, c)), isFalse);
    });

    test('one corner alone always fits amber (placed), so the second corner_rejected toast '
        '(fit.quality == none) could never fire after a switch', () {
      final fit = const AlignmentEstimator().fit([matcher.firstCorner(snapAt(bedroom[3]), bedroom[3])]);
      expect(fit.quality, AlignmentQuality.placed);
    });
  });

  group('tolerance per method', () {
    test('depth sensor: 10°, tracked planes: 15°, rough methods: 20°', () {
      expect(CornerMatcher.angleToleranceFor('lidar'), 10);
      expect(CornerMatcher.angleToleranceFor('planes'), 15);
      expect(CornerMatcher.angleToleranceFor('floorTap'), 20);
      expect(CornerMatcher.angleToleranceFor('depthTaps'), 20);
    });

    test('93° (real out-of-square room) matches by every method; 102° only by planes or rough', () {
      final c = bedroom[3];
      for (final m in ['lidar', 'planes', 'floorTap']) {
        expect(matcher.shapeMatches(snapAt(c, method: m), c), isTrue, reason: m);
      }
      expect(matcher.shapeMatches(snapAt(c, angle: 102, method: 'lidar'), c), isFalse);
      expect(matcher.shapeMatches(snapAt(c, angle: 102, method: 'planes'), c), isTrue);
      // A 135° splay is never a 90° corner.
      expect(matcher.shapeMatches(snapAt(c, angle: 135, method: 'floorTap'), c), isFalse);
    });

    test('a column snap is an outside corner; never an inside one', () {
      final d = snapAt(bedroom[0], kind: 'outside');
      expect(matcher.shapeMatches(d, bedroom[0]), isTrue);
      expect(matcher.shapeMatches(d, bedroom[3]), isFalse);
    });
  });

  group('fallbackFor — every floor corner, nearest to where the user is', () {
    test('bedroom: inside snap with a column picked → the inside corner next to it', () {
      final fb = matcher.fallbackFor(snapAt(bedroom[3]), bedroom[0], bedroom);
      expect(fb.kind, ShapeFallbackKind.switched);
      expect(fb.candidate!.id, 'in-nw'); // 0.33 m from the picked column corner
      expect(fb.distanceM, lessThan(0.5));
    });

    test('bedroom: the snapped shape matches the pick → nothing to do', () {
      expect(matcher.fallbackFor(snapAt(bedroom[4]), bedroom[4], bedroom).kind, ShapeFallbackKind.matches);
    });

    test('the camera position, when known, beats the picked corner', () {
      final fb = matcher.fallbackFor(snapAt(bedroom[5]), bedroom[0], bedroom, near: const Vec3(3, 1.5, -0.5));
      expect(fb.candidate!.id, 'in-se');
    });

    test('STTCC: no inside corner anywhere → noneOfShape (not this room)', () {
      final fb = matcher.fallbackFor(roomSnap, sttcc()[1], sttcc());
      expect(fb.kind, ShapeFallbackKind.noneOfShape);
      expect(fb.snappedShape, 'inside');
      expect(fb.nearbyShape, 'outside');
    });

    test('STTCC with one office 40 m away → nearbyOtherShape, office offered, not taken', () {
      final all = sttcc(withFarRoom: true);
      final fb = matcher.fallbackFor(roomSnap, all[1], all);
      expect(fb.kind, ShapeFallbackKind.nearbyOtherShape);
      expect(fb.candidate!.id, 'office');
      expect(fb.sameShape.map((c) => c.id), ['office']);
    });
  });

  group('ArSetupController.useCornerA — the owner\'s flow end to end', () {
    late ProviderContainer container;
    late _Session session;

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    Future<ArSetupController> open(List<CornerCandidate> corners) async {
      session = _Session(ArSessionState(
        phase: ArSessionPhase.running,
        args: const ArSessionArgs(floorId: 'f1', method: ArPlaceMethod.corners),
        floor: _floor(corners),
      ));
      container = ProviderContainer(overrides: [arSessionProvider.overrideWith(() => session)]);
      container.listen(arSessionProvider, (_, _) {});
      container.listen(arSetupProvider, (_, _) {});
      await settle();
      return container.read(arSetupProvider.notifier);
    }

    ArSetupState setup() => container.read(arSetupProvider);

    tearDown(() => container.dispose());

    test('bedroom, column picked, inside corner snapped at 93° → switched, placed, corner B next', () async {
      final ctrl = await open(bedroom);
      expect(setup().step, ArSetupStep.start);
      ctrl.chooseCornerA(bedroom.firstWhere((c) => c.id == 'col-nw'));
      ctrl.startCornerA();
      session.injectDemoCorner(snapAt(bedroom.firstWhere((c) => c.id == 'in-nw')));
      await settle();
      expect(setup().snapped, isNotNull);

      ctrl.useCornerA();
      expect(setup().step, ArSetupStep.cornerB);
      expect(setup().cornerAId, 'in-nw');
      expect(setup().chosenA!.id, 'in-nw');
      expect(session.state.quality, AlignmentQuality.placed);
      // The coach strip's notice names the corner by the same pin number
      // the plan shows; nothing is toasted over the camera.
      final pin = setup().pinOf(setup().chosenA);
      expect(setup().noticeKey, 'ar.toast.corner_switched');
      expect(setup().noticeArgs, [pin!, 'Bedroom 1 · NW corner']);
      expect(session.toasts, isEmpty);
      expect(pin, 1); // inside corners are offered first
    });

    test('bedroom, matching corner → straight to corner B, no toast at all', () async {
      final ctrl = await open(bedroom);
      ctrl.chooseCornerA(bedroom[4]);
      ctrl.startCornerA();
      session.injectDemoCorner(snapAt(bedroom[4]));
      await settle();
      ctrl.useCornerA();
      expect(setup().step, ArSetupStep.cornerB);
      expect(session.toasts, isEmpty);
    });

    test('STTCC, inside corner snapped → explained mismatch, no toast; a second tap buzzes', () async {
      final corners = sttcc();
      final ctrl = await open(corners);
      expect(setup().pinOf(setup().ranked[1]), 2);
      ctrl.chooseCornerA(setup().ranked[1]); // "#2 · Column · NW corner"
      ctrl.startCornerA();
      session.injectDemoCorner(roomSnap);
      await settle();

      ctrl.useCornerA();
      expect(setup().step, ArSetupStep.cornerA);
      expect(setup().cornerProblem, ArCornerProblem.noneOfShape);
      expect(setup().problemShape, 'inside');
      expect(session.toasts, isEmpty);
      expect(session.state.fit, isNull);

      final seq = setup().problemSeq;
      ctrl.useCornerA();
      expect(session.toasts, isEmpty);
      expect(setup().problemSeq, seq + 1);
    });

    test('STTCC with a far office → "nearby corners are column corners"; the office gets a pin', () async {
      final ctrl = await open(sttcc(withFarRoom: true));
      ctrl.chooseCornerA(setup().ranked[1]);
      ctrl.startCornerA();
      session.injectDemoCorner(roomSnap);
      await settle();
      ctrl.useCornerA();
      expect(setup().cornerProblem, ArCornerProblem.otherShapeNearby);
      expect(session.toasts, isEmpty);
      final office = setup().ranked.firstWhere((c) => c.id == 'office');
      expect(setup().pinOf(office), isNotNull);

      // Tapping the office on the plan clears the explanation; the same
      // snap now places the model.
      ctrl.chooseCornerA(office);
      expect(setup().cornerProblem, isNull);
      ctrl.useCornerA();
      expect(setup().step, ArSetupStep.cornerB);
    });
  });

  group('ArMiniPlan at phone size', () {
    // A data-hall plan: 30 equipment items with long element tags.
    final plan = ArPlan(
      minX: -2,
      minZ: -18,
      maxX: 24,
      maxZ: 2,
      walls: const [],
      wallThicknesses: const [],
      equipment: [
        for (var i = 0; i < 30; i++)
          ArPlanEquipment(
            name: 'STTCC-EB-00-EMV01-EE-${1000 + i}',
            polygon: [
              Vec2(1 + (i % 6) * 3.5, -1 - (i ~/ 6) * 3.0),
              Vec2(2.5 + (i % 6) * 3.5, -1 - (i ~/ 6) * 3.0),
              Vec2(2.5 + (i % 6) * 3.5, -2 - (i ~/ 6) * 3.0),
            ],
          ),
      ],
    );

    Widget host(ArMiniPlan p) => MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(width: 326, height: 140, child: p))),
    );

    int paragraphs(WidgetTester tester) {
      var n = 0;
      final box = tester.renderObject(find.descendant(of: find.byType(ArMiniPlan), matching: find.byType(CustomPaint)).first);
      expect(
        box,
        paints
          ..everything((method, args) {
            if (method == #drawParagraph) n++;
            return true;
          }),
      );
      return n;
    }

    testWidgets('no element tags, no overlapping numbered pins, selected pin numbered, expand button', (tester) async {
      final corners = sttcc();
      CornerCandidate? tapped;
      final focus = corners[1].posTile.xz;
      final widget = ArMiniPlan(
        plan: plan,
        corners: corners,
        selectedCornerId: corners[1].id,
        focus: focus,
        focusRadiusM: ArMiniPlan.fitRadius(focus, corners),
        zoomable: true,
        onExpand: () {},
        onTapCorner: (c) => tapped = c,
      );
      await tester.pumpWidget(host(widget));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);

      final pins = debugLayoutPins(widget, const Size(326, 140));
      final full = pins.where((p) => p.full).toList();
      for (var i = 0; i < full.length; i++) {
        for (var j = i + 1; j < full.length; j++) {
          final ri = full[i].id == corners[1].id ? 12.0 : 9.0;
          final rj = full[j].id == corners[1].id ? 12.0 : 9.0;
          expect((full[i].at - full[j].at).distance, greaterThanOrEqualTo(ri + rj), reason: '${full[i].id} vs ${full[j].id}');
        }
      }
      expect(full.any((p) => p.id == corners[1].id && p.number == 2), isTrue);
      expect(pins.any((p) => !p.full), isTrue, reason: 'a column\'s four corners collapse into dots');

      // Only pin numbers and stars are text: none of the 30 element tags.
      expect(paragraphs(tester), lessThanOrEqualTo(full.length + 3));
      expect(find.byKey(const ValueKey('ar-plan-expand')), findsOneWidget);

      // Tapping the selected pin picks it.
      final origin = tester.getTopLeft(find.byType(ArMiniPlan));
      final sel = full.firstWhere((p) => p.id == corners[1].id);
      await tester.tapAt(origin + sel.at);
      await tester.pump(const Duration(milliseconds: 50));
      expect(tapped?.id, corners[1].id);
    });

    testWidgets('element tags only when asked for', (tester) async {
      final widget = ArMiniPlan(plan: plan, showEquipmentNames: true);
      await tester.pumpWidget(host(widget));
      await tester.pump(const Duration(milliseconds: 50));
      // Off by default (the plan is too small for tags at this zoom anyway,
      // so check the flag reaches the painter via a zoomed-in frame).
      final zoomed = ArMiniPlan(plan: plan, showEquipmentNames: true, focus: const Vec2(3, -3), focusRadiusM: 3);
      await tester.pumpWidget(host(zoomed));
      await tester.pump(const Duration(milliseconds: 50));
      final withTags = paragraphs(tester);
      await tester.pumpWidget(host(ArMiniPlan(plan: plan, focus: const Vec2(3, -3), focusRadiusM: 3)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(paragraphs(tester), 0);
      expect(withTags, greaterThan(0));
    });

    testWidgets('dims corners of the other shape after a mismatch', (tester) async {
      final corners = sttcc(withFarRoom: true);
      final widget = ArMiniPlan(corners: corners, matchShape: 'inside');
      final pins = debugLayoutPins(widget, const Size(326, 140));
      expect(pins.firstWhere((p) => p.id == 'office').dim, isFalse);
      expect(pins.where((p) => p.id != 'office').every((p) => p.dim), isTrue);
    });

    test('fitRadius frames a room, not the floor', () {
      final r = ArMiniPlan.fitRadius(bedroom[3].posTile.xz, bedroom);
      expect(r, inInclusiveRange(3.5, 9));
      expect(ArMiniPlan.fitRadius(const Vec2(0, 0), const []), 3.5);
    });
  });

  group('the setup overlay on a small iPhone, the owner\'s scenario', () {
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
      for (final size in const [Size(375, 667), Size(390, 844), Size(844, 390)]) {
        testWidgets('guide once, then STTCC mismatch explained, no overflow — ${size.width.round()}×${size.height.round()} $lang',
            (tester) async {
          FlutterLocalization.instance.translate(lang);
          tester.view.physicalSize = size * 3;
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          final corners = sttcc();
          final session = _Session(ArSessionState(
            phase: ArSessionPhase.running,
            tracking: ArTracking.tracking,
            args: const ArSessionArgs(floorId: 'f1', method: ArPlaceMethod.corners),
            floor: _floor(corners),
          ));
          final store = _PrefStore({'coach:v1': '1'});
          await tester.pumpWidget(ProviderScope(
            overrides: [
              arSessionProvider.overrideWith(() => session),
              arPackStoreProvider.overrideWithValue(store),
            ],
            child: MaterialApp(
              theme: AppTheme.build(),
              supportedLocales: FlutterLocalization.instance.supportedLocales,
              localizationsDelegates: FlutterLocalization.instance.localizationsDelegates,
              locale: Locale(lang),
              home: const Scaffold(backgroundColor: Colors.black, body: ArSetupOverlay(tablet: false, topInset: 80)),
            ),
          ));
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          // The three-step guide comes up before the first corner.
          final strings = _strings(lang);
          expect(find.text(strings['ar.setup_guide.step1_title'] as String), findsOneWidget);
          await tester.ensureVisible(find.byKey(const ValueKey('ar-guide-dont-show')));
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('ar-guide-dont-show')));
          await tester.pump();
          await tester.ensureVisible(find.text(strings['ar.setup_guide.go'] as String));
          await tester.pump();
          await tester.tap(find.text(strings['ar.setup_guide.go'] as String));
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(store.prefs['setupGuide:v1'], '1');
          expect(tester.takeException(), isNull);

          final container = ProviderScope.containerOf(tester.element(find.byType(ArSetupOverlay)));
          final ctrl = container.read(arSetupProvider.notifier);
          ctrl.chooseCornerA(container.read(arSetupProvider).ranked[1]);
          ctrl.startCornerA();
          session.injectDemoCorner(roomSnap);
          await tester.pump(const Duration(milliseconds: 100));
          ctrl.useCornerA();
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(tester.takeException(), isNull);
          final strip = tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('ar-coach-text')), matching: find.byType(Text)));
          expect(strip.data, strings['ar.coach.cue.wrong_model']);
          expect(find.byKey(const ValueKey('ar-corner-problem')), findsOneWidget);
          expect(find.text(strings['ar.corner.pick_floor'] as String), findsOneWidget);
          expect(find.text(strings['ar.corner.try_demo'] as String), findsOneWidget);
          expect(session.toasts, isEmpty);

          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 7));
        });
      }
    }
  });
}
