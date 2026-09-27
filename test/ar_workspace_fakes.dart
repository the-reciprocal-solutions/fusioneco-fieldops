import 'dart:typed_data';

import 'package:technician_portal/core/ar/alignment_estimator.dart';
import 'package:technician_portal/core/ar/ar_engine.dart' show ArCapabilities;
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/state/ar_gateway.dart';
import 'package:technician_portal/state/ar_session_controller.dart';
import 'package:technician_portal/state/ar_view_models.dart';

/// Shared by the AR workspace tests: a small two-build floor (arch + MEP
/// with colliding feature ids, a cable inside a wall) and hand-written fakes
/// of the session controller and the gateway.

// ------------------------------------------------------------------ fixtures

ArFeature feat(
  String build,
  int id,
  String gid,
  String type,
  String discipline,
  Vec3 min,
  Vec3 max, {
  String? assetId,
  Map<String, String> props = const {},
}) => ArFeature(
  buildId: build,
  featureId: id,
  globalId: gid,
  ifcType: type,
  discipline: discipline,
  bboxMin: min,
  bboxMax: max,
  assetId: assetId,
  props: props,
);

// Two builds whose dense feature ids collide (CONTRACT C4): arch#0 and mep#0.
final wall = feat('arch', 0, 'g-wall', 'IfcWall', 'architecture', const Vec3(0, 0, -0.1), const Vec3(10, 3, 0.1));
final slab = feat('arch', 1, 'g-slab', 'IfcSlab', 'structure', const Vec3(0, 3, -5), const Vec3(10, 3.2, 5));
final pipe = feat('mep', 0, 'g-pipe', 'IfcPipeSegment', 'plumbing', const Vec3(1, 2.4, 2), const Vec3(9, 2.5, 2.1));
// A cable inside the wall (faces at z = ±0.1), right behind x = 5.
final cable = feat('mep', 1, 'g-cable', 'IfcCableSegment', 'electrical', const Vec3(4.5, 1.0, -0.02), const Vec3(5.5, 1.02, 0.02));
final pump = feat('mep', 2, 'g-pump', 'IfcPump', 'mechanical', const Vec3(7, 0, 3), const Vec3(8, 0.8, 4), props: {'Pset.Tag': 'P-01'});

const floor = ArFloorContext(
  buildingId: 'b1',
  buildingName: 'Tower',
  floorId: 'f1',
  floorName: 'Level 1',
  builds: [],
  tiles: [],
  markers: [],
  corners: [],
  gridLines: [],
);

const plan = ArPlan(
  minX: -1,
  minZ: -6,
  maxX: 11,
  maxZ: 6,
  walls: [
    [Vec2(0, 0), Vec2(10, 0)],
  ],
  wallThicknesses: [0.2],
);

AlignmentFit placedFit() => AlignmentFit(
  yawRad: 0,
  t: Vec3.zero,
  arFromTile: Mat4.identity(),
  maxResidualM: 0.01,
  residualsM: const {},
  outliers: const [],
  spreadM: 3,
  quality: AlignmentQuality.placed,
  observationCount: 2,
);

ArSessionState session({bool demo = false, ArCapabilities? caps}) => ArSessionState(
  phase: ArSessionPhase.running,
  stage: ArSessionStage.work,
  demo: demo,
  floor: floor,
  plan: plan,
  features: [wall, slab, pipe, cable, pump],
  capabilities: caps,
);

// --------------------------------------------------------------------- fakes

class FakeGateway implements ArGateway {
  ArProgressSnapshot snapshot = const ArProgressSnapshot();
  ArProgressWriteResult next = const ArProgressWriteResult(updated: 1);
  final writes = <(List<String>, ArProgressStatus)>[];

  @override
  bool get isDemo => false;

  @override
  Future<ArProgressSnapshot> progress(String floorId) async => snapshot;

  @override
  Future<ArProgressWriteResult> setProgress({
    required String floorId,
    required List<String> globalIds,
    required ArProgressStatus status,
    String? note,
  }) async {
    writes.add((globalIds, status));
    return next;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class FakeSession extends ArSessionController {
  FakeSession(this.initial, this.gw);

  final ArSessionState initial;
  final FakeGateway gw;

  final textures = <String?, Uint8List>{};
  final widths = <String?, int>{};
  final sectionYs = <double?>[];
  var pickManyCalls = 0;
  List<(double, double)> lastPickMany = const [];
  List<ArPickHit?> Function(List<(double, double)>)? pickManyAnswer;
  final torchCalls = <bool>[];

  @override
  ArSessionState build() => initial;

  void put(ArSessionState s) => state = s;

  @override
  ArGateway? get gateway => gw;

  @override
  Future<void> setFeatureState(Uint8List rgba, int width, {String? buildId}) async {
    textures[buildId] = rgba;
    widths[buildId] = width;
  }

  @override
  Future<void> setLayers({
    required bool mep,
    required bool structure,
    required bool architecture,
    required double opacity,
    double? sectionY,
  }) async {
    sectionYs.add(sectionY);
  }

  @override
  Future<void> setPins(List<ArPinSpec> pins) async {}

  @override
  Future<void> setTargetFeature(ArFeature? f) async => state = f == null ? state.copyWith(clearTarget: true) : state.copyWith(target: f);

  @override
  Future<ArPickHit?> pick(double x, double y) async => null;

  @override
  Future<List<ArPickHit?>> pickMany(List<(double, double)> points) async {
    pickManyCalls++;
    lastPickMany = points;
    return pickManyAnswer?.call(points) ?? [for (final _ in points) null];
  }

  @override
  Future<bool> setTorch(bool on) async {
    torchCalls.add(on);
    state = state.copyWith(torchOn: on);
    return true;
  }

  @override
  void toast(String key, {List<Object> args = const [], ArToastTone tone = ArToastTone.info}) {}
}

