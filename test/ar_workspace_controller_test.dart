import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/ar_engine.dart' show ArCapabilities;
import 'package:technician_portal/core/ar/feature_state.dart';
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/state/ar_session_controller.dart';
import 'package:technician_portal/state/ar_view_models.dart';
import 'package:technician_portal/state/ar_workspace_controller.dart';
import 'package:technician_portal/theme/fe_ar_colors.dart';

import 'ar_workspace_fakes.dart';

/// ArWorkspaceController (PENDING P-009): legend filters, per-build feature
/// state, x-ray / section, the progress palette, four-eyes blockers, the
/// queued-refusal re-check (P-008 (2)), lasso via `pickMany`, drill check
/// and torch — against a hand-written session fake (no engine, no DB).

// ---------------------------------------------------------------------- tests

void main() {
  late ProviderContainer container;
  late FakeSession fake;
  late FakeGateway gw;

  ArWorkspaceController ctl() => container.read(arWorkspaceProvider.notifier);
  ArWorkspaceState ws() => container.read(arWorkspaceProvider);

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void make(ArSessionState s) {
    gw = FakeGateway();
    fake = FakeSession(s, gw);
    container = ProviderContainer(overrides: [arSessionProvider.overrideWith(() => fake)]);
    container.listen(arSessionProvider, (_, _) {});
    container.listen(arWorkspaceProvider, (_, _) {});
  }

  tearDown(() => container.dispose());

  (int, int, int, int) texel(String build, int id) {
    final t = fake.textures[build]!;
    return (t[id * 4], t[id * 4 + 1], t[id * 4 + 2], t[id * 4 + 3]);
  }

  int rgbOf((int, int, int, int) t) => (t.$1 << 16) | (t.$2 << 8) | t.$3;

  group('legend filters', () {
    test('counts per chip, cached per feature list', () {
      make(session());
      final c = ctl().disciplineCounts();
      expect(c[ArDiscipline.walls], 1);
      expect(c[ArDiscipline.structure], 1);
      expect(c[ArDiscipline.plumbing], 1);
      expect(c[ArDiscipline.electrical], 1);
      expect(c[ArDiscipline.hvac], 1, reason: 'mechanical reads as HVAC');
      expect(identical(ctl().disciplineCounts(), c), isTrue);
    });

    test('long-press solos a discipline, keeps wall edges, second press restores', () {
      make(session());
      ctl().soloDiscipline(ArDiscipline.electrical);
      final l = ws().layers;
      expect(l.shows(ArDiscipline.electrical), isTrue);
      expect(l.shows(ArDiscipline.plumbing), isFalse);
      expect(l.shows(ArDiscipline.structure), isFalse);
      expect(l.shows(ArDiscipline.walls), isTrue, reason: 'edges stay: the live alignment check');
      expect(l.isSolo(ArDiscipline.electrical), isTrue);
      ctl().toggleDiscipline(ArDiscipline.electrical);
      expect(ws().layers.solo, isNull);
      expect(ArDiscipline.values.every(ws().layers.shows), isTrue);
    });

    test('showing one MEP chip while the MEP model is off brings back just that one', () {
      make(session());
      ctl().setLayers(ws().layers.copyWith(mep: false));
      ctl().setDisciplineShown(ArDiscipline.fire, true);
      final l = ws().layers;
      expect(l.mep, isTrue);
      expect(l.shows(ArDiscipline.fire), isTrue);
      expect(l.shows(ArDiscipline.plumbing), isFalse);
    });
  });

  group('per-build feature state', () {
    test('one texture per build; hiding plumbing hides mep#0 only, never arch#0', () async {
      make(session());
      ctl().toggleDiscipline(ArDiscipline.plumbing);
      await settle();
      expect(fake.textures.keys, containsAll(<String>['arch', 'mep']));
      expect(texel('mep', 0).$4, FeatureDisplay.hidden.alpha);
      expect(texel('arch', 0).$4, isNot(FeatureDisplay.hidden.alpha));
    });

    test('discipline colours tint MEP, slabs are ghosted', () async {
      make(session());
      ctl().setLayers(ws().layers);
      await settle();
      expect(rgbOf(texel('mep', 1)), arDisciplineRgb('electrical'));
      expect(texel('arch', 1).$4, FeatureDisplay.ghost.alpha);
    });

    test('the selection is highlighted in its own build only', () async {
      make(session());
      ctl().selectOnly(pipe);
      await settle();
      expect(texel('mep', 0).$4, FeatureDisplay.highlight.alpha);
      expect(rgbOf(texel('mep', 0)), kHighlightRgb);
      expect(texel('arch', 0).$4, isNot(FeatureDisplay.highlight.alpha));
    });

    test('progress mode uses the legend palette; not started is ghosted slate', () async {
      make(session(demo: true));
      gw.snapshot = const ArProgressSnapshot(entries: {
        'g-pipe': ArProgressEntry(globalId: 'g-pipe', status: ArProgressStatus.installed, installedBy: 'x'),
        'g-cable': ArProgressEntry(globalId: 'g-cable', status: ArProgressStatus.verified, installedBy: 'x', verifiedBy: 'y'),
      });
      ctl().setMode(ArMode.progress);
      await settle();
      expect(rgbOf(texel('mep', 0)), FeArColors.installed.toARGB32() & 0xFFFFFF);
      expect(texel('mep', 0).$4, FeatureDisplay.normal.alpha);
      expect(rgbOf(texel('mep', 1)), FeArColors.verified.toARGB32() & 0xFFFFFF);
      expect(texel('mep', 2).$4, FeatureDisplay.ghost.alpha, reason: 'pump not started');
      expect(rgbOf(texel('mep', 2)), kArNotStartedRgb);
    });

    test('x-ray draws concealed MEP through walls in its own colour', () async {
      make(session());
      ctl().toggleXray();
      await settle();
      expect(ws().layers.xray, isTrue);
      expect(texel('mep', 1).$4, FeatureDisplay.highlight.alpha, reason: 'cable is in the wall');
      expect(rgbOf(texel('mep', 1)), arDisciplineRgb('electrical'));
      expect(texel('mep', 2).$4, isNot(FeatureDisplay.highlight.alpha), reason: 'pump stands in the room');
    });

    test('a drifting fit dims everything but keeps the selection', () {
      final tex = ArWorkspaceController.featureStateFor(
        buildId: 'mep',
        ofBuild: [pipe, cable, pump],
        ws: ArWorkspaceState(selection: [pump]),
        target: null,
        ghostOthers: false,
        dimAll: true,
      );
      expect(tex.texel(0).$4, FeatureDisplay.ghost.alpha);
      expect(tex.texel(1).$4, FeatureDisplay.ghost.alpha);
      expect(tex.texel(2).$4, FeatureDisplay.highlight.alpha);
    });
  });

  group('section cut', () {
    test('slider moves the cut above the floor datum; off clears it', () async {
      make(session());
      ctl().setSectionHeight(2.0);
      await settle();
      expect(ws().layers.section, isTrue);
      expect(fake.sectionYs.last, closeTo(2.0, 1e-9));
      ctl().setSectionHeight(9);
      expect(ws().layers.sectionHeightM, kArSectionMaxM);
      ctl().toggleSection();
      await settle();
      expect(fake.sectionYs.last, isNull);
    });

    test('dragging updates the value without pushing', () async {
      make(session());
      final before = fake.sectionYs.length;
      ctl().setSectionHeight(1.1, push: false);
      await settle();
      expect(fake.sectionYs.length, before);
      expect(ws().layers.sectionHeightM, 1.1);
    });
  });

  group('four-eyes', () {
    test('blockers: not installed, or installed by me', () async {
      make(session(demo: true));
      gw.snapshot = const ArProgressSnapshot(entries: {
        'g-pipe': ArProgressEntry(globalId: 'g-pipe', status: ArProgressStatus.installed, installedBy: 'demo-me'),
        'g-cable': ArProgressEntry(globalId: 'g-cable', status: ArProgressStatus.installed, installedBy: 'someone'),
      });
      ctl().setMode(ArMode.progress);
      await settle();
      ctl().setSelectMode(ArSelectMode.multi);
      ctl().selectOnly(pipe);
      await ctl().tap(0, 0, demoHit: cable);
      await ctl().tap(0, 0, demoHit: pump);
      final b = {for (final r in ctl().verifyBlockers()) r.globalId: r.reason};
      expect(b['g-pipe'], 'SECOND_PERSON_REQUIRED');
      expect(b['g-pump'], 'NOT_INSTALLED');
      expect(b.containsKey('g-cable'), isFalse);
    });

    test('a failed write paints nothing', () async {
      make(session(demo: true));
      gw.next = const ArProgressWriteResult(errorCode: 'ERROR');
      ctl().selectOnly(pump);
      await ctl().setStatus(ArProgressStatus.installed);
      expect(ws().progress.statusOf('g-pump'), ArProgressStatus.notStarted);
      expect(ws().progressBusy, isFalse);
    });

    test('a queued write the server refused on replay is reported (P-008 (2))', () async {
      make(session(demo: true));
      gw.next = const ArProgressWriteResult(updated: 1, queued: true);
      ctl().selectOnly(pump);
      await ctl().setStatus(ArProgressStatus.installed);
      expect(ws().progress.statusOf('g-pump'), ArProgressStatus.installed, reason: 'optimistic while queued');
      expect(ws().progressQueued, 1);
      // Queue drained; the server kept "not started".
      gw.snapshot = const ArProgressSnapshot();
      final refused = await ctl().recheckQueuedProgress();
      expect(refused, ['g-pump']);
      expect(ws().progressQueued, 0);
      expect(ws().rejections.single.reason, kArRefusedOnSync);
      expect(ws().progress.statusOf('g-pump'), ArProgressStatus.notStarted);
    });

    test('a queued write the server accepted reports nothing', () async {
      make(session(demo: true));
      gw.next = const ArProgressWriteResult(updated: 1, queued: true);
      ctl().selectOnly(pump);
      await ctl().setStatus(ArProgressStatus.installed);
      gw.snapshot = const ArProgressSnapshot(entries: {
        'g-pump': ArProgressEntry(globalId: 'g-pump', status: ArProgressStatus.installed, installedBy: 'demo-me'),
      });
      expect(await ctl().recheckQueuedProgress(), isEmpty);
      expect(ws().rejections, isEmpty);
    });
  });

  group('lasso', () {
    test('one batched pickMany, merged and de-duplicated', () async {
      make(session());
      fake.pickManyAnswer = (pts) => [
        for (var i = 0; i < pts.length; i++)
          i.isEven ? const ArPickHit(featureId: 2, buildId: 'mep') : const ArPickHit(featureId: 0, buildId: 'arch'),
      ];
      await ctl().lasso(const [(0, 0), (300, 0), (300, 300), (0, 300)]);
      expect(fake.pickManyCalls, 1);
      expect(fake.lastPickMany.length, lessThanOrEqualTo(450));
      expect(ws().selection.map((f) => f.globalId), unorderedEquals(['g-pump', 'g-wall']));
    });

    test('samples stay inside the polygon and near the cap', () {
      final tri = [(0.0, 0.0), (400.0, 0.0), (0.0, 400.0)];
      final s = ArWorkspaceController.lassoSamples(tri, maxSamples: 120);
      expect(s, isNotEmpty);
      expect(s.length, lessThanOrEqualTo(130));
      expect(s.every((p) => p.$1 + p.$2 <= 400), isTrue);
    });
  });

  group('drill check', () {
    test('not placed → says so', () {
      make(session());
      ctl().toggleDrill();
      expect(ws().drilling, isTrue);
      expect(ws().drill?.status, ArDrillStatus.notPlaced);
    });

    test('aimed at the wall over the cable → a warning naming the cable', () {
      make(session().copyWith(fit: placedFit(), cameraAr: const Vec3(5, 1.0, 2), cameraForwardAr: const Vec3(0, 0, -1)));
      ctl().toggleDrill();
      final r = ws().drill!;
      expect(r.status, anyOf(ArDrillStatus.danger, ArDrillStatus.caution));
      expect(r.feature?.globalId, 'g-cable');
    });

    test('Measure and Drill are exclusive', () {
      make(session());
      ctl().toggleDrill();
      ctl().toggleMeasure();
      expect(ws().drilling, isFalse);
      expect(ws().measuring, isTrue);
    });
  });

  group('torch', () {
    test('no torch on this device → false, nothing sent', () async {
      make(session(caps: const ArCapabilities(supported: true)));
      expect(await ctl().toggleTorch(), isFalse);
      expect(fake.torchCalls, isEmpty);
      expect(ws().torchSupported, isFalse);
    });

    test('with a torch → through the session, state follows it', () async {
      make(session(caps: const ArCapabilities(supported: true, torch: true)));
      expect(await ctl().toggleTorch(), isTrue);
      expect(fake.torchCalls, [true]);
      expect(ws().torch, isTrue);
      await ctl().toggleTorch();
      expect(fake.torchCalls, [true, false]);
      expect(ws().torch, isFalse);
    });
  });

  test('element facts: a run gets length and size, concealment from the plan', () {
    make(session());
    final f = ctl().factsFor(cable);
    expect(f.runLengthM, closeTo(1.0, 1e-9));
    expect(f.placement?.bottomM, closeTo(1.0, 1e-9));
    expect(f.discipline, ArDiscipline.electrical);
  });
}
