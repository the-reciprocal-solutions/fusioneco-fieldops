import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/ar_engine.dart';
import 'package:technician_portal/core/ar/fake_ar_engine.dart';
import 'package:technician_portal/core/ar/manual_place_math.dart';
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/domain/ar_models.dart' show ManifestTile;
import 'package:technician_portal/state/ar_catalog_controller.dart' show arGatewayProvider;
import 'package:technician_portal/state/ar_gateway.dart';
import 'package:technician_portal/state/ar_session_controller.dart';
import 'package:technician_portal/state/ar_view_models.dart';
import 'package:technician_portal/state/providers.dart' show arEngineProvider, arPackStoreProvider;

import 'manual_place_test_fakes.dart' show PrefStore;

/// "Sometimes the model elements are not displaying" (owner, iPhone, after
/// "Place by hand", 2026-10-09). The real [ArSessionController] against a
/// fake engine whose tile loads can be held, like a native decode that
/// takes a while: which tiles end up resident when a placement happens
/// while a load is still running, or moves the model without the camera
/// moving.
///
/// The floor has three tile clusters 40 m apart along X. Before anything is
/// placed the session loads around the floor's focus point (cluster A); the
/// user stands still at AR (0, 1.5, 0) the whole time.

ManifestTile _tile(String hash, double x) => ManifestTile(
      hash: hash,
      url: '/t/$hash',
      bytes: 1000,
      layer: 'mep',
      bboxMin: Vec3(x, 0, 0),
      bboxMax: Vec3(x + 4, 3, 4),
      triangleCount: 1000,
      buildId: 'b1',
    );

final _floor = ArFloorContext(
  buildingId: 'bld',
  buildingName: 'Tower',
  floorId: 'f1',
  floorName: 'Level 1',
  builds: const [],
  tiles: [_tile('a', 0), _tile('b', 40), _tile('c', 80)],
  markers: const [],
  corners: const [],
  gridLines: const [],
);

class _Gateway implements ArGateway {
  @override
  bool get isDemo => false;

  @override
  Future<ArFloorContext> floorContext(String floorId, {String? focusCode}) async => _floor;

  @override
  Future<void> download(ArFloorContext floor, {void Function(ArDownloadProgress progress)? onProgress}) async {}

  @override
  Future<Map<String, String>> tilePaths(List<ManifestTile> tiles) async => {for (final t in tiles) t.hash: '/tiles/${t.hash}.glb'};

  @override
  Future<ArPlan?> floorPlan(String floorId) async => null;

  @override
  Future<List<ArFeature>> features(ArFloorContext floor, {Set<String>? tileHashes}) async => const [];

  @override
  Future<void> postAlignmentEvents(List<ArAlignmentReport> reports) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// The native tile store's behaviour that matters here (FeArTiles.swift /
/// TileStore.kt): a load answers only once every tile is decoded, `stop`
/// unloads everything, and a tile still loading when `stop` arrives is
/// reported failed ("unloaded while loading") and never becomes resident.
class _SlowEngine extends FakeArEngine {
  _SlowEngine() : super(autoplay: false, script: FakeArScript.manual);

  /// While set, loads wait for it (a slow native decode).
  Completer<void>? gate;
  final requests = <List<String>>[];
  var _generation = 0;

  @override
  Future<TileLoadResult> loadTiles(List<TileRef> tiles) async {
    final asked = [for (final t in tiles) t.hash];
    requests.add(asked);
    final g = _generation;
    final hold = gate;
    if (hold != null) await hold.future;
    if (g != _generation) {
      return TileLoadResult(loaded: const [], failed: {for (final h in asked) h: 'unloaded while loading'});
    }
    return super.loadTiles(tiles);
  }

  @override
  Future<void> stop() async {
    _generation++;
    loadedTiles.clear();
    await super.stop();
  }
}

class _Rig {
  _Rig() {
    container = ProviderContainer(overrides: [
      arPackStoreProvider.overrideWithValue(PrefStore()),
      arEngineProvider.overrideWithValue(engine),
      arGatewayProvider.overrideWithValue(_Gateway()),
    ]);
    container.listen(arSessionProvider, (_, _) {});
  }

  final engine = _SlowEngine();
  late final ProviderContainer container;
  var _jiggle = false;

  ArSessionController get ctrl => container.read(arSessionProvider.notifier);
  ArSessionState get s => container.read(arSessionProvider);

  Future<void> start() async {
    final f = ctrl.start(const ArSessionArgs(floorId: 'f1'));
    // startSession waits for the platform view (onViewCreated).
    for (var i = 0; i < 200 && s.phase != ArSessionPhase.loading && s.phase != ArSessionPhase.running; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    ctrl.onViewCreated(1);
    await f;
    expect(s.phase, ArSessionPhase.running);
    await settle();
  }

  /// The user standing still (a few centimetres of hand shake, which the
  /// session's pose throttle lets through).
  Future<void> stillPose() async {
    _jiggle = !_jiggle;
    engine.simulatePose(Mat4.fromYawTranslation(0, Vec3(_jiggle ? 0.06 : 0, 1.5, 0)));
    await settle();
  }

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

/// A hand placement that puts the model's [pivotTile] on the floor under
/// the user (AR origin): the user then stands at tile (pivot.x, 1.5,
/// pivot.z).
ManualPlacement _placeAt(Vec3 pivotTile) =>
    ManualPlacement(pose: const ManualPose(pos: Vec2(0, 0)), pivotTile: pivotTile);

void main() {
  late _Rig r;

  setUp(() {
    r = _Rig();
    addTearDown(r.container.dispose);
  });

  test('before placement, the tiles around the focus point load', () async {
    await r.start();
    await r.stillPose();
    expect(r.engine.loadedTiles, {'a'});
  });

  test('a hand placement locked while a tile load is still running gets the tiles around the user', () async {
    r.engine.gate = Completer<void>();
    await r.start(); // the first pass loads A; held
    await r.stillPose();
    expect(r.engine.requests, [
      ['a'],
    ]);
    // Lock with the user standing in cluster B (40 m from A).
    await r.ctrl.applyManualPlacement(_placeAt(const Vec3(42, 0, 2)));
    r.engine.gate!.complete();
    r.engine.gate = null;
    await r.settle();
    for (var i = 0; i < 3; i++) {
      await r.stillPose();
    }
    expect(r.engine.loadedTiles, contains('b'), reason: 'the placement request made while A was loading must not be dropped');
    expect(r.engine.loadedTiles, isNot(contains('a')), reason: 'A is 38 m away now: unloaded');
  });

  test('re-placing an already placed model loads the tiles around the user without walking', () async {
    await r.start();
    await r.stillPose();
    await r.ctrl.applyManualPlacement(_placeAt(const Vec3(2, 0, 2)));
    await r.stillPose();
    expect(r.engine.loadedTiles, {'a'});
    // "Place by hand" again, much further along the floor.
    await r.ctrl.applyManualPlacement(_placeAt(const Vec3(82, 0, 2)));
    await r.stillPose();
    expect(r.engine.loadedTiles, contains('c'));
  });

  test('the see-through preview loads the tiles under the model being placed', () async {
    await r.start();
    await r.stillPose();
    r.ctrl.beginManualPreview();
    await r.ctrl.previewModelTransform(_placeAt(const Vec3(42, 0, 2)).arFromTile);
    await r.stillPose();
    expect(r.engine.loadedTiles, contains('b'));
  });

  test('a load still running from the previous session never counts as resident in the new one', () async {
    r.engine.gate = Completer<void>();
    await r.start(); // the first pass loads A; held across the restart
    await r.stillPose();
    final restart = r.ctrl.restart();
    for (var i = 0; i < 200 && r.s.phase == ArSessionPhase.running; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    for (var i = 0; i < 200 && r.s.phase != ArSessionPhase.loading && r.s.phase != ArSessionPhase.running; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    r.ctrl.onViewCreated(1);
    await restart;
    r.engine.gate!.complete(); // the old session's load answers now: failed
    r.engine.gate = null;
    await r.settle();
    for (var i = 0; i < 3; i++) {
      await r.stillPose();
    }
    expect(r.engine.loadedTiles, {'a'});
  });
}
