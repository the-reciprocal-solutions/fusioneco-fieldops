import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/state/ar_engine_extras.dart';
import 'package:technician_portal/state/ar_labels.dart';
import 'package:technician_portal/state/ar_view_models.dart';
import 'package:technician_portal/state/ar_workspace_controller.dart';

/// Floating labels (pure): which elements get a chip, their short names,
/// and the on-screen layout from projected points.

ArFeature f(int id, String name, String type, {String disc = 'plumbing', Map<String, String> props = const {}}) => ArFeature(
  buildId: 'mep',
  featureId: id,
  globalId: 'g$id',
  name: name,
  ifcType: type,
  discipline: disc,
  bboxMin: Vec3(id.toDouble(), 0, 0),
  bboxMax: Vec3(id + 1.0, 2, 1),
  props: props,
);

void main() {
  const view = Size(400, 800);

  group('shortName', () {
    test('prefers a short tag, else the name, ellipsised', () {
      expect(ArLabels.shortName(f(1, 'Air handling unit', 'IfcUnitaryEquipment', props: {'Pset_X.Tag': 'AHU-03'})), 'AHU-03');
      expect(ArLabels.shortName(f(2, 'CHW supply', 'IfcPipeSegment')), 'CHW supply');
      expect(ArLabels.shortName(f(3, 'A very long element name that goes on and on', 'IfcPipeSegment')).length, lessThanOrEqualTo(26));
    });
  });

  group('anchorsFor', () {
    test('target first unless drawn elsewhere; duplicates collapse; capped', () {
      final t = f(1, 'Target', 'IfcPump');
      final sel = [for (var i = 1; i <= 12; i++) f(i, 'E$i', 'IfcPipeSegment')];
      final a = ArLabels.anchorsFor(selection: sel, target: t, targetDrawnElsewhere: false);
      expect(a.first.kind, ArLabelKind.target);
      expect(a.where((x) => x.feature?.featureId == 1).length, 1);
      expect(a.length, ArLabels.maxLabels);

      final b = ArLabels.anchorsFor(selection: sel.take(2).toList(), target: t, targetDrawnElsewhere: true);
      expect(b.map((x) => x.feature!.featureId), [2], reason: 'the target (also selected) is labelled by the Locate overlay');
    });

    test('snag pins sit 20 cm over the element and carry the snag id', () {
      final e = f(4, 'Pump', 'IfcPump');
      final a = ArLabels.anchorsFor(
        selection: const [],
        target: null,
        targetDrawnElsewhere: false,
        snagPins: [ArSnagPin(snagId: 's1', title: 'Leak', feature: e)],
      );
      expect(a.single.kind, ArLabelKind.snag);
      expect(a.single.snagId, 's1');
      expect(a.single.posTile.y, closeTo(2.2, 1e-9));
      expect(ArLabels.anchorsFor(selection: const [], target: null, targetDrawnElsewhere: false, snagPins: [ArSnagPin(snagId: 's1', title: 'Leak', feature: e)], showSnags: false), isEmpty);
    });

    test('runs hang at their middle, boxes at the top', () {
      expect(ArLabels.anchorPoint(f(1, 'p', 'IfcPipeSegment')).y, 1);
      expect(ArLabels.anchorPoint(f(1, 'u', 'IfcPump')).y, 2);
    });
  });

  group('layout', () {
    List<ArLabelAnchor> anchors(int n) => ArLabels.anchorsFor(
      selection: [for (var i = 1; i <= n; i++) f(i, 'E$i', 'IfcPump')],
      target: null,
      targetDrawnElsewhere: false,
    );

    test('behind the camera, off screen or unprojected → no chip', () {
      final a = anchors(4);
      final placed = ArLabels.layout(
        anchors: a,
        points: const [ArScreenPoint(100, 300), ArScreenPoint(100, 300, onScreen: false), ArScreenPoint(-5, 300), null],
        view: view,
      );
      expect(placed.map((p) => p.anchor.feature!.featureId), [1]);
      expect(placed.single.rect.bottom, lessThanOrEqualTo(300), reason: 'above its point');
    });

    test('colliding chips step apart instead of overlapping', () {
      final a = anchors(3);
      final placed = ArLabels.layout(
        anchors: a,
        points: const [ArScreenPoint(200, 400), ArScreenPoint(202, 401), ArScreenPoint(204, 402)],
        view: view,
      );
      expect(placed.length, 3);
      for (var i = 0; i < placed.length; i++) {
        for (var j = i + 1; j < placed.length; j++) {
          expect(placed[i].rect.overlaps(placed[j].rect), isFalse);
        }
      }
    });

    test('chips stay inside the safe area', () {
      final placed = ArLabels.layout(
        anchors: anchors(1),
        points: const [ArScreenPoint(385, 130)],
        view: view,
        safe: const Rect.fromLTRB(8, 120, 392, 500),
      );
      final r = placed.single.rect;
      expect(r.right, lessThanOrEqualTo(392));
      expect(r.top, greaterThanOrEqualTo(120));
    });
  });

  group('ArScreenPoint.parse', () {
    test('records, lists and channel maps', () {
      expect(ArScreenPoint.parse((1.0, 2.0, false))!.onScreen, isFalse);
      expect(ArScreenPoint.parse([3, 4, true])!.x, 3);
      expect(ArScreenPoint.parse({'x': 5, 'y': 6, 'onScreen': true})!.y, 6);
      expect(ArScreenPoint.parse(null), isNull);
      expect(ArScreenPoint.parseList([null, [1, 2]], 3), [null, isA<ArScreenPoint>(), null]);
    });
  });

  test('projectTile is a guarded no-op on an engine without it', () async {
    final extras = ArEngineExtras(Object());
    expect(await extras.projectTile(const [Vec3(0, 0, 0)]), isNull);
    expect(extras.canProject, isFalse);
    expect(await ArEngineExtras(null).projectTile(const [Vec3(0, 0, 0)]), isNull);
  });

  test('projectTile resolves to an engine that has it', () async {
    final extras = ArEngineExtras(_Projector());
    final pts = await extras.projectTile(const [Vec3(1, 2, 3)]);
    expect(pts!.single!.x, 10);
    expect(pts.single!.onScreen, isTrue);
  });

  // Keeps the import used: the anchors key on the controller's disciplines.
  test('discipline of a label', () {
    expect(ArLabels.anchorsFor(selection: [f(1, 'c', 'IfcCableSegment', disc: 'electrical')], target: null, targetDrawnElsewhere: false).single.discipline, ArDiscipline.electrical);
  });
}

class _Projector {
  Future<List<(double, double, bool)?>> projectTile(List<Vec3> pts) async => [for (final p in pts) (p.x * 10, p.y * 10, true)];
}
