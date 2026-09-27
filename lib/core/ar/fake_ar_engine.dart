import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../domain/ar_models.dart';
import 'ar_engine.dart';
import 'corner_matcher.dart';
import 'ghost_spot.dart';
import 'marker_code.dart';
import 'vec.dart';

/// A small, fully specified demo floor: "Level 3" of "Tower A (demo)" with
/// Plant Room B (no boards yet, a column C-2 in the middle, a pump) and a
/// riser corridor with two active boards. Everything the AR flows need —
/// manifest, plan, corners, grid, boards, features — so every screen can be
/// walked in Demo mode (and in widget tests) with no server and no native
/// AR. The hidden truth ([truthYawDeg], [truthT]) is what a correct fit
/// must recover from the fake engine's sightings.
abstract final class ArDemoScenario {
  static const buildingId = 'demo-building';
  static const buildingName = 'Tower A (demo)';
  static const floorId = 'demo-level-3';
  static const floorName = 'Level 3';
  static const buildId = 'demo-mep-7';

  /// Where the model really is in the fake AR world.
  static const truthYawDeg = 30.0;
  static const truthT = Vec3(1.2, -1.45, -0.8);

  static Mat4 get truth => Mat4.fromYawTranslation(degToRad(truthYawDeg), truthT);

  /// The two corners the scripted corner flow snaps, in order: column C-2
  /// (the best-ranked, what corner A's picker suggests first) and the room
  /// corner by the door, about 7.1 m away (matched automatically as B).
  static const cornerAId = 'c-col-c2-nw';
  static const cornerBId = 'c-pr-b-door';

  static const corners = <CornerCandidate>[
    // Column C-2, 0.5 m square at (6, 4): four outside corners.
    CornerCandidate(
      id: cornerAId,
      posTile: Vec3(5.75, 0, 3.75),
      faceA: Vec2(-1, 0),
      faceB: Vec2(0, -1),
      angleDeg: 90,
      kind: 'column',
      structural: true,
      rank: 0.95,
      label: 'Plant Room B · column C-2',
    ),
    CornerCandidate(
      id: 'c-col-c2-ne',
      posTile: Vec3(6.25, 0, 3.75),
      faceA: Vec2(1, 0),
      faceB: Vec2(0, -1),
      angleDeg: 90,
      kind: 'column',
      structural: true,
      rank: 0.9,
      label: 'Plant Room B · column C-2, east face',
    ),
    CornerCandidate(
      id: 'c-col-c2-se',
      posTile: Vec3(6.25, 0, 4.25),
      faceA: Vec2(1, 0),
      faceB: Vec2(0, 1),
      angleDeg: 90,
      kind: 'column',
      structural: true,
      rank: 0.88,
      label: 'Plant Room B · column C-2, south face',
    ),
    // Plant Room B, 12 × 8 m: four inside corners.
    CornerCandidate(
      id: 'c-pr-b-nw',
      posTile: Vec3(0, 0, 0),
      faceA: Vec2(1, 0),
      faceB: Vec2(0, 1),
      angleDeg: 90,
      kind: 'inside',
      structural: true,
      rank: 0.8,
      label: 'Plant Room B · north-west corner',
    ),
    CornerCandidate(
      id: 'c-pr-b-ne',
      posTile: Vec3(12, 0, 0),
      faceA: Vec2(-1, 0),
      faceB: Vec2(0, 1),
      angleDeg: 90,
      kind: 'inside',
      structural: true,
      rank: 0.78,
      label: 'Plant Room B · north-east corner',
    ),
    CornerCandidate(
      id: 'c-pr-b-se',
      posTile: Vec3(12, 0, 8),
      faceA: Vec2(-1, 0),
      faceB: Vec2(0, -1),
      angleDeg: 90,
      kind: 'inside',
      rank: 0.6,
      label: 'Plant Room B · south-east corner',
    ),
    CornerCandidate(
      id: cornerBId,
      posTile: Vec3(0, 0, 8),
      faceA: Vec2(1, 0),
      faceB: Vec2(0, -1),
      angleDeg: 90,
      kind: 'inside',
      rank: 0.7,
      label: 'Plant Room B · corner by the door',
    ),
    // Riser corridor, 12 × 4 m.
    CornerCandidate(
      id: 'c-rc-nw',
      posTile: Vec3(14, 0, 0),
      faceA: Vec2(1, 0),
      faceB: Vec2(0, 1),
      angleDeg: 90,
      kind: 'inside',
      structural: true,
      rank: 0.65,
      label: 'Riser corridor · west end',
    ),
    CornerCandidate(
      id: 'c-rc-se',
      posTile: Vec3(26, 0, 4),
      faceA: Vec2(-1, 0),
      faceB: Vec2(0, -1),
      angleDeg: 90,
      kind: 'inside',
      structural: true,
      rank: 0.62,
      label: 'Riser corridor · east end',
    ),
  ];

  /// Active boards in the riser corridor, 6.9 m apart — the board-scan flow
  /// (M1–M5). Plant Room B has none, so the corner flow ends with "leave a
  /// board".
  static const boardAId = '7K3QX9R'; // L03-M07
  static const boardBId = 'M0R5E85'; // L03-M06

  static const markers = <ManifestMarker>[
    ManifestMarker(
      code: boardAId,
      label: 'L03-M07',
      status: 'active',
      accuracyClass: 'feature',
      mounting: 'wall',
      posTile: Vec3(14, 1.5, 2),
      normalTile: Vec3(1, 0, 0),
      sigmaM: 0.02,
    ),
    ManifestMarker(
      code: boardBId,
      label: 'L03-M06',
      status: 'active',
      accuracyClass: 'feature',
      mounting: 'wall',
      posTile: Vec3(20.7, 1.5, 0),
      normalTile: Vec3(0, 0, 1),
      sigmaM: 0.02,
    ),
  ];

  /// A spare from the van's pack: label `SP-4Q2M`.
  static const spareCode = '4Q2MA76';

  static const webHost = 'FE.EXAMPLE';

  static const gridLines = <ArGridLine>[
    ArGridLine(name: 'A', p0: Vec2(0, -1), p1: Vec2(0, 9)),
    ArGridLine(name: 'B', p0: Vec2(6, -1), p1: Vec2(6, 9)),
    ArGridLine(name: 'C', p0: Vec2(12, -1), p1: Vec2(12, 9)),
    ArGridLine(name: '1', p0: Vec2(-1, 0), p1: Vec2(27, 0)),
    ArGridLine(name: '2', p0: Vec2(-1, 4), p1: Vec2(27, 4)),
    ArGridLine(name: '3', p0: Vec2(-1, 8), p1: Vec2(13, 8)),
  ];

  static const pumpGlobalId = '2O2Fr\$t4X7Zf8NOew3FLOH';
  static const valveGlobalId = '1kTvXnbbzCWw8lcMd1dR4o';

  static List<ArFeature> features() => const [
        ArFeature(
          buildId: buildId,
          featureId: 1,
          globalId: pumpGlobalId,
          assetId: 'demo-asset-p02',
          floorId: floorId,
          name: 'Pump P-02',
          discipline: 'mechanical',
          systemGlobalId: 'sys-chw',
          ifcType: 'IfcPump',
          bboxMin: Vec3(9, 0, 1),
          bboxMax: Vec3(10.5, 1.2, 2.5),
        ),
        ArFeature(
          buildId: buildId,
          featureId: 2,
          globalId: valveGlobalId,
          assetId: 'demo-asset-v12',
          floorId: floorId,
          name: 'Isolation valve V-12',
          discipline: 'mechanical',
          systemGlobalId: 'sys-chw',
          ifcType: 'IfcValve',
          bboxMin: Vec3(8.4, 2.1, 1.6),
          bboxMax: Vec3(8.7, 2.4, 1.9),
        ),
        ArFeature(
          buildId: buildId,
          featureId: 3,
          globalId: '0eA6m4fELI9QBIhP3wiLAp',
          floorId: floorId,
          name: 'CHW flow pipe',
          discipline: 'mechanical',
          systemGlobalId: 'sys-chw',
          ifcType: 'IfcPipeSegment',
          bboxMin: Vec3(1, 2.3, 1.7),
          bboxMax: Vec3(11, 2.5, 1.9),
        ),
      ];

  static List<ArBuildRef> builds() => [
        ArBuildRef(
          buildId: buildId,
          lineage: 'mep',
          modelName: 'MEP',
          version: 7,
          publishedAt: DateTime.utc(2026, 9, 20, 9),
          coordMatrix: Mat4.identity(),
          buildingFrame: Mat4.identity(),
        ),
      ];

  static Manifest manifest() => Manifest(
        buildingId: buildingId,
        floorId: floorId,
        floorName: floorName,
        builds: builds(),
        corners: corners,
        gridLines: gridLines,
        markers: markers,
        etag: 'demo',
      );

  static FloorPlan plan() => const FloorPlan(
        floorId: floorId,
        bounds: PlanBounds(-1, -1, 27, 9),
        walls: [
          PlanWall(polyline: [Vec2(0, 0), Vec2(12, 0), Vec2(12, 8), Vec2(3, 8)], structural: true),
          PlanWall(polyline: [Vec2(2, 8), Vec2(0, 8), Vec2(0, 0)], structural: true),
          PlanWall(polyline: [Vec2(14, 0), Vec2(26, 0), Vec2(26, 4), Vec2(14, 4), Vec2(14, 0)]),
        ],
        columns: [
          PlanColumn(polygon: [Vec2(5.75, 3.75), Vec2(6.25, 3.75), Vec2(6.25, 4.25), Vec2(5.75, 4.25)]),
        ],
        openings: [PlanOpening(kind: 'door', a: Vec2(2, 8), b: Vec2(3, 8))],
        spaces: [
          PlanSpace(
            name: 'Plant Room B',
            polygon: [Vec2(0, 0), Vec2(12, 0), Vec2(12, 8), Vec2(0, 8)],
            labelAt: Vec2(3, 2),
          ),
          PlanSpace(
            name: 'Riser corridor',
            polygon: [Vec2(14, 0), Vec2(26, 0), Vec2(26, 4), Vec2(14, 4)],
            labelAt: Vec2(20, 2),
          ),
        ],
        equipment: [
          PlanEquipment(
            globalId: pumpGlobalId,
            name: 'Pump P-02',
            assetId: 'demo-asset-p02',
            polygon: [Vec2(9, 1), Vec2(10.5, 1), Vec2(10.5, 2.5), Vec2(9, 2.5)],
          ),
        ],
        gridLines: gridLines,
        corners: corners,
      );

  static ArFloorSummary floor() => const ArFloorSummary(
        floorId: floorId,
        name: floorName,
        elevation: 9.6,
        models: [
          ArFloorModel(
            lineage: 'mep',
            modelName: 'MEP',
            buildId: buildId,
            version: 7,
            bytes: 3100000,
            status: ArModelStatus.ready,
            onDevice: true,
          ),
          ArFloorModel(
            lineage: 'arch',
            modelName: 'Architecture',
            status: ArModelStatus.noIfc,
            reason: 'Source IFC missing',
          ),
        ],
        markerCount: 2,
        cornerCount: 9,
        gridNames: ['A', 'B', 'C', '1', '2', '3'],
      );

  /// What resolving a demo board returns ("Model is on this phone").
  static MarkerResolution? resolution(String code) {
    final canonical = MarkerCode.normalize(code) ?? code;
    final known = manifest().markerByCode(canonical);
    final ArMarker marker;
    if (known != null) {
      marker = ArMarker(
        code: known.code,
        label: known.label,
        status: known.status,
        accuracyClass: known.accuracyClass,
        buildingId: buildingId,
        floorId: floorId,
        mounting: known.mounting,
        posTile: known.posTile,
        normalTile: known.normalTile,
        heightAboveFloorM: known.posTile.y,
        confirmations: 4,
      );
    } else if (canonical == spareCode) {
      marker = const ArMarker(
        code: spareCode,
        label: 'SP-4Q2M',
        status: ArMarkerStatus.spare,
        accuracyClass: 'derived',
        buildingId: buildingId,
      );
    } else {
      return null;
    }
    return MarkerResolution(
      marker: marker,
      building: const ArNamedRef(id: buildingId, name: buildingName),
      floor: const ArNamedRef(id: floorId, name: floorName),
      builds: builds(),
      focusBytes: 3100000,
      totalBytes: 14000000,
      fromCache: true,
      packOnDevice: true,
    );
  }
}

/// Which story the fake engine plays after `startSession`.
enum FakeArScript {
  /// S1–S4: tracking; corners hovered under the pin (snapped when the UI
  /// calls `detectCornerAt`); after corner B, a spare board is sighted where
  /// the ghost board shows; later a drift.
  corners,

  /// M1–M5: tracking; board L03-M07 locks (about 1 s after start), then
  /// L03-M06 as the user walks; later a drift.
  boards,

  /// Tracking only; the screen (or a test) drives everything through the
  /// `simulate*` methods.
  manual,
}

/// A scripted [ArEngine] for tests and the in-app Demo mode (which must show
/// a visible "Demo" banner: nothing here is real).
///
/// It observes [ArDemoScenario]'s floor through a hidden truth transform,
/// with millimetre noise, so the real pipeline — `CornerMatcher`,
/// `AlignmentEstimator`, `InstallCheck` — runs unchanged on its output and
/// genuinely locks. With [autoplay] it runs on its own timer (Demo mode);
/// without, tests move its clock with [advance] and read [emitted].
class FakeArEngine implements ArEngine {
  FakeArEngine({
    this.script = FakeArScript.corners,
    this.autoplay = true,
    ArCapabilities? capabilities,
    this.tick = const Duration(milliseconds: 200),
  }) : _capabilities = capabilities ??
            const ArCapabilities(
              supported: true,
              depth: true,
              lidar: true,
              platform: 'demo',
              // So the torch button can be tried in Demo mode (it lights nothing).
              torch: true,
            );

  final FakeArScript script;
  final bool autoplay;
  final Duration tick;
  final ArCapabilities _capabilities;

  final _controller = StreamController<ArEvent>.broadcast();

  /// Every command received, in order (`setModelTransform`, `loadTiles`, …).
  final List<String> commands = [];

  /// Every event emitted, in order.
  final List<ArEvent> emitted = [];

  Mat4? lastTransform;
  final Set<String> loadedTiles = {};
  LayerState layers = const LayerState();
  List<int>? target;

  /// The build [target]'s ids belong to (null: the call named none).
  String? targetBuildId;
  List<ArPin> pins = const [];
  List<GridLineRef> gridLines = const [];

  /// The last texture sent, whichever build it was for.
  Uint8List? featureState;
  int featureStateWidth = 0;

  /// Every build's current texture, keyed by the call's `buildId` (null for
  /// an unscoped one), as the native side keeps them.
  final Map<String?, Uint8List> featureStatesByBuild = {};

  /// When set, the next `detectCornerAt` snaps this candidate instead of the
  /// script's next corner — Demo mode sets it to the corner the user picked
  /// on the mini plan, so the demo always agrees with the user.
  String? aimCornerId;

  /// What the next `depthPointAt` calls answer, in order (tests queue wall
  /// taps here); empty means "nothing measured" (null).
  final List<ArDepthPoint?> depthPoints = [];

  /// The torch as the last `setTorch` left it.
  bool torchOn = false;

  /// The `recordTo` / `playbackFrom` of the last `startSession`, and a
  /// recording started with `startRecording` (Demo mode never writes one).
  String? recordTo;
  String? playbackFrom;
  String? recordingPath;

  Timer? _timer;
  bool _running = false;
  bool _paused = false;
  int _elapsedMs = 0;
  int _cornerIndex = 0;
  int _sightings = 0;
  int _boardsSeen = 0;
  int? _cornersDoneAtMs;
  bool _spareSighted = false;
  bool _drifted = false;
  Vec3 _drift = Vec3.zero;
  final List<(int, void Function())> _schedule = [];

  bool get isRunning => _running && !_paused;
  Duration get elapsed => Duration(milliseconds: _elapsedMs);

  @override
  Stream<ArEvent> get events => _controller.stream;

  @override
  Future<ArCapabilities> capabilities() async {
    commands.add('capabilities');
    return _capabilities;
  }

  @override
  Future<void> startSession({String? recordTo, String? playbackFrom}) async {
    commands.add('startSession');
    this.recordTo = recordTo;
    this.playbackFrom = playbackFrom;
    torchOn = false;
    _running = true;
    _paused = false;
    _elapsedMs = 0;
    _cornerIndex = 0;
    _boardsSeen = 0;
    _cornersDoneAtMs = null;
    _spareSighted = false;
    _drifted = false;
    _drift = Vec3.zero;
    _schedule.clear();
    _at(300, () => _emit(const TrackingEvent(state: ArTracking.initializing, reason: 'initializing')));
    _at(1200, () => _emit(const TrackingEvent(state: ArTracking.tracking)));
    switch (script) {
      case FakeArScript.corners:
        break; // corners are hovered on each tick; see _onTick
      case FakeArScript.boards:
        _at(2200, () => simulateMarker(ArDemoScenario.boardAId));
        _at(9000, () => simulateMarker(ArDemoScenario.boardBId));
        _at(25000, simulateDrift);
      case FakeArScript.manual:
        break;
    }
    if (autoplay) {
      _timer?.cancel();
      _timer = Timer.periodic(tick, (_) => advance(tick));
    }
  }

  /// Moves the fake clock by [by], emitting everything due. Tests call this
  /// directly (with `autoplay: false`); Demo mode's timer calls it each tick.
  void advance(Duration by) {
    if (!_running || _paused) return;
    final end = _elapsedMs + by.inMilliseconds;
    while (_elapsedMs < end) {
      final step = math.min(tick.inMilliseconds, end - _elapsedMs);
      _elapsedMs += step;
      _runDue();
      _onTick();
    }
  }

  void _at(int ms, void Function() action) => _schedule.add((ms, action));

  void _runDue() {
    final due = _schedule.where((s) => s.$1 <= _elapsedMs).toList();
    _schedule.removeWhere((s) => s.$1 <= _elapsedMs);
    for (final (_, action) in due) {
      action();
    }
  }

  void _onTick() {
    if (_elapsedMs < 1200) return; // not tracking yet
    _emit(CameraPoseEvent(arFromCamera: _cameraPose()));
    if (target != null) {
      final phase = (_elapsedMs ~/ 1000) % 4;
      _emit(TargetScreenEvent(x: 120.0 + phase * 40, y: 360, onScreen: phase != 3));
    }
    if (script == FakeArScript.corners) {
      // The pin hovers over the next corner: a snap preview every 1.5 s.
      if (_cornerIndex < 2 && _elapsedMs % 1500 < tick.inMilliseconds) {
        _emit(_sightCorner(_scriptedCornerId()));
      }
      final done = _cornersDoneAtMs;
      if (done != null && !_spareSighted && _elapsedMs >= done + 6000) {
        simulateSpare();
      }
      if (done != null && !_drifted && _elapsedMs >= done + 18000) {
        simulateDrift();
      }
    }
  }

  // ------------------------------------------------------------- simulation

  /// A corner snapped under the pin for [candidateId] (default: the next
  /// scripted corner). Emitted as a [CornerSeenEvent] and returned.
  CornerSeenEvent simulateCorner([String? candidateId]) {
    final e = _sightCorner(candidateId ?? _scriptedCornerId());
    _emit(e);
    return e;
  }

  /// A board sighting for [code] (a demo board, or the spare), with the
  /// payload a real QR would carry.
  MarkerSeenEvent simulateMarker(String code, {double? qrEdgeMm = 115.2}) {
    final canonical = MarkerCode.normalize(code) ?? code;
    final known = ArDemoScenario.manifest().markerByCode(canonical);
    final Vec3 pos;
    final Vec3 normal;
    if (known != null) {
      pos = known.posTile;
      normal = known.normalTile;
      _boardsSeen++;
    } else {
      final ghost = ghostSpot();
      pos = ghost?.posTile ?? const Vec3(3.2, 1.5, 0);
      normal = ghost?.normalTile ?? const Vec3(0, 0, 1);
    }
    final t = _truth();
    final e = MarkerSeenEvent(
      rawPayload: MarkerCode.qrPayload(canonical, webHost: ArDemoScenario.webHost),
      anchorId: 'anchor-$canonical',
      centreAr: t.transformPoint(pos) + _noise(),
      normalAr: t.transformDir(normal),
      method: _capabilities.lidar ? 'lidar' : 'plane',
      spreadMm: 4,
      distanceM: 1.1,
      viewAngleDeg: 8,
      qrEdgeMm: qrEdgeMm,
    );
    _emit(e);
    return e;
  }

  /// The spare board, stuck up where the ghost board shows.
  MarkerSeenEvent simulateSpare() {
    _spareSighted = true;
    return simulateMarker(ArDemoScenario.spareCode);
  }

  /// Tracking drifts by [metres]: a short relocalisation, then every later
  /// sighting (and the spare's anchor) is off by that much — what the
  /// runtime drift check and a re-snap must catch ("Corrected 4 cm").
  void simulateDrift({double metres = 0.04}) {
    _drifted = true;
    _emit(const TrackingEvent(state: ArTracking.limited, reason: 'relocalizing'));
    _drift = _drift + Vec3(metres, 0, 0);
    if (_spareSighted) {
      final ghost = ghostSpot();
      if (ghost != null) {
        _emit(AnchorUpdatedEvent(
          anchorId: 'anchor-${ArDemoScenario.spareCode}',
          posAr: _truth().transformPoint(ghost.posTile),
        ));
      }
    }
    _at(_elapsedMs + 800, () => _emit(const TrackingEvent(state: ArTracking.tracking)));
  }

  void simulateTrackingLost({String reason = 'insufficientFeatures'}) {
    _emit(TrackingEvent(state: ArTracking.limited, reason: reason));
    _at(_elapsedMs + 1500, () => _emit(const TrackingEvent(state: ArTracking.tracking)));
  }

  /// Where the demo's ghost board goes (and so where the spare is sighted).
  GhostSpot? ghostSpot() => const GhostSpotFinder().best(
        corners: [
          for (final c in ArDemoScenario.corners)
            if (c.label.startsWith('Plant Room B')) c,
        ],
        markers: ArDemoScenario.markers,
        cameraTile: const Vec3(3, 1.5, 5),
        plan: ArDemoScenario.plan(),
      );

  /// The camera position in the tile frame right now (for tests and the
  /// demo's "you are here" dot). It stands where a real user would for the
  /// current step — in front of column C-2 for corner A, inside the room by
  /// the door for corner B and the ghost board, a metre from each board in
  /// the board script — with a gentle hand sway. Standing on the visible
  /// side matters: the corner matcher orients faces toward the camera.
  Vec3 cameraTile() {
    final t = _elapsedMs / 1000.0;
    final sway = Vec3(0.15 * math.sin(t * 0.8), 0.03 * math.sin(t * 1.3), 0.12 * math.cos(t * 0.6));
    return _cameraBase() + sway;
  }

  Vec3 _cameraBase() {
    if (script == FakeArScript.boards) {
      return _boardsSeen == 0 ? const Vec3(15.1, 1.5, 2.1) : const Vec3(20.6, 1.5, 1.2);
    }
    return _cornerIndex == 0 ? const Vec3(3.2, 1.5, 1.8) : const Vec3(2.6, 1.5, 5.6);
  }

  Vec3 _lookAt() {
    if (script == FakeArScript.boards) {
      return _boardsSeen == 0 ? ArDemoScenario.markers[0].posTile : ArDemoScenario.markers[1].posTile;
    }
    return _cornerIndex == 0 ? const Vec3(5.75, 1.2, 3.75) : const Vec3(0, 1.2, 7);
  }

  // --------------------------------------------------------------- commands

  @override
  Future<void> loadTiles(List<TileRef> tiles) async {
    commands.add('loadTiles');
    loadedTiles.addAll(tiles.map((t) => t.hash));
  }

  @override
  Future<void> unloadTiles(List<String> hashes) async {
    commands.add('unloadTiles');
    loadedTiles.removeAll(hashes);
  }

  @override
  Future<void> setModelTransform(Mat4 arFromTile, {int easeMs = 300}) async {
    commands.add('setModelTransform');
    lastTransform = arFromTile;
  }

  @override
  Future<void> setFeatureState(Uint8List rgba, int width, {String? buildId}) async {
    commands.add('setFeatureState');
    featureState = rgba;
    featureStateWidth = width;
    featureStatesByBuild[buildId] = rgba;
  }

  @override
  Future<void> setLayers(LayerState s) async {
    commands.add('setLayers');
    layers = s;
  }

  @override
  Future<void> setTarget(List<int>? featureIds, {String? buildId}) async {
    commands.add('setTarget');
    target = featureIds;
    targetBuildId = featureIds == null ? null : buildId;
  }

  @override
  Future<void> setGridLines(List<GridLineRef> lines, double floorY) async {
    commands.add('setGridLines');
    gridLines = lines;
  }

  @override
  Future<void> setPins(List<ArPin> pins) async {
    commands.add('setPins');
    this.pins = pins;
  }

  @override
  Future<CornerSeenEvent?> detectCornerAt(double x, double y) async {
    commands.add('detectCornerAt');
    if (!_running || _elapsedMs < 1200) return null; // not tracking yet
    final id = aimCornerId ?? _scriptedCornerId();
    aimCornerId = null;
    final e = _sightCorner(id);
    _cornerIndex++;
    if (_cornerIndex >= 2) _cornersDoneAtMs ??= _elapsedMs;
    return e;
  }

  @override
  Future<String?> anchorAt(Vec3 posAr) async {
    commands.add('anchorAt');
    return null; // the demo world never drifts
  }

  @override
  Future<PickResult?> pick(double x, double y) async {
    commands.add('pick');
    final pump = ArDemoScenario.features().first;
    return PickResult(
      featureId: pump.featureId,
      hitPointTile: pump.centre ?? Vec3.zero,
      distanceM: 3.4,
      buildId: ArDemoScenario.buildId,
    );
  }

  @override
  Future<List<(double, double, bool)?>> projectTile(List<Vec3> pointsTile) async {
    commands.add('projectTile');
    // Demo mode places its labels itself on the painted sample room.
    return [for (final _ in pointsTile) null];
  }

  @override
  Future<List<PickResult?>> pickMany(List<(double, double)> points) async {
    commands.add('pickMany');
    final pump = ArDemoScenario.features().first;
    return [
      for (final _ in points)
        PickResult(
          featureId: pump.featureId,
          hitPointTile: pump.centre ?? Vec3.zero,
          distanceM: 3.4,
          buildId: ArDemoScenario.buildId,
        ),
    ];
  }

  @override
  Future<ArDepthPoint?> depthPointAt(double x, double y) async {
    commands.add('depthPointAt');
    if (depthPoints.isEmpty) return null;
    return depthPoints.removeAt(0);
  }

  @override
  Future<bool> setDepth(bool on) async {
    commands.add('setDepth');
    return true;
  }

  @override
  Future<bool> refocus() async {
    commands.add('refocus');
    return true;
  }

  @override
  Future<bool> setTorch(bool on) async {
    commands.add('setTorch');
    torchOn = on;
    return _capabilities.torch;
  }

  @override
  Future<bool> startRecording(String path) async {
    commands.add('startRecording');
    recordingPath = path;
    return true;
  }

  @override
  Future<String?> stopRecording() async {
    commands.add('stopRecording');
    final path = recordingPath;
    recordingPath = null;
    return path;
  }

  @override
  Future<String?> capture() async {
    commands.add('capture');
    return null; // Demo mode has no camera frame to save.
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    _paused = true;
  }

  @override
  Future<void> resume() async {
    commands.add('resume');
    _paused = false;
  }

  @override
  Future<void> stop() async {
    commands.add('stop');
    _running = false;
    torchOn = false;
    recordingPath = null;
    _timer?.cancel();
    _timer = null;
  }

  /// Closes the event stream; the engine can't be restarted after this.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  // ---------------------------------------------------------------- helpers

  void _emit(ArEvent e) {
    emitted.add(e);
    if (!_controller.isClosed) _controller.add(e);
  }

  Mat4 _truth() => Mat4.fromYawTranslation(
        degToRad(ArDemoScenario.truthYawDeg),
        ArDemoScenario.truthT + _drift,
      );

  Mat4 _cameraPose() {
    final cam = cameraTile();
    final forwardTile = (_lookAt() - cam).normalized;
    final t = _truth();
    final posAr = t.transformPoint(cam);
    final fwdAr = t.transformDir(forwardTile);
    // Camera looks down its −Z: yaw that maps (0, 0, −1) onto fwdAr.
    final yaw = headingOf(fwdAr.xz) - headingOf(const Vec2(0, -1));
    return Mat4.fromYawTranslation(yaw, posAr);
  }

  String _scriptedCornerId() =>
      _cornerIndex == 0 ? ArDemoScenario.cornerAId : ArDemoScenario.cornerBId;

  CornerSeenEvent _sightCorner(String candidateId) {
    final c = ArDemoScenario.corners.firstWhere(
      (c) => c.id == candidateId,
      orElse: () => ArDemoScenario.corners.first,
    );
    final t = _truth();
    final yaw = degToRad(ArDemoScenario.truthYawDeg);
    // Faces come back in the opposite order to the model's, as a real
    // detector may: the matcher's pairing must sort that out.
    return CornerSeenEvent(
      posAr: t.transformPoint(c.posTile) + _noise(),
      faceAAr: rotateXz(c.faceB, yaw),
      faceBAr: rotateXz(c.faceA, yaw),
      angleDeg: c.angleDeg,
      kind: c.kind,
      method: _capabilities.lidar ? 'lidar' : 'planes',
    );
  }

  /// Deterministic millimetre noise, different for each sighting.
  Vec3 _noise() {
    final i = ++_sightings;
    return Vec3(0.003 * math.sin(i * 1.7), 0.002 * math.cos(i * 0.9), -0.003 * math.cos(i * 1.3));
  }
}
