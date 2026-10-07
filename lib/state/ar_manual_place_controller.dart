import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ar/alignment_estimator.dart' show AlignmentQuality;
import '../core/ar/ar_engine.dart' show ArPlane, ArPlanes, ArRay;
import '../core/ar/manual_place_math.dart';
import '../core/ar/vec.dart';
import 'ar_prefs_controller.dart' show ArPlaceMethod, arPrefsProvider;
import 'ar_session_controller.dart';
import 'ar_setup_controller.dart';
import 'ar_view_models.dart';
import 'providers.dart';

/// "Place by hand" (docs/ar-implementation.md §2.7): an additional setup
/// method next to corners and boards. The model appears in front of the
/// user at true size; they drag it on the floor, twist it, pinch it, snap a
/// face to a wall or a corner to a room corner, then lock it.
///
/// Native executes, Dart decides, as everywhere in AR: every pose comes from
/// [ManualGestures] / [ManualSnaps] (pure, unit-tested); the engine only
/// gives rays, planes and projections ([ManualViewIo]) and draws the matrix
/// the session previews. Locking hands the pose to
/// [ArSessionController.applyManualPlacement], which makes it the session's
/// fit ([AlignmentQuality.manual], anchored) — the workspace then opens
/// exactly as after a corner placement.
///
/// Lives beside `ArSetupController` without touching it: the session
/// screen shows this overlay instead of the setup overlay while [active].

/// The gesture/engine seam: rays through view points, AR-world points to
/// view points, tracked planes, and a native corner snap. The live one goes
/// through the session's engine; Demo mode uses a drawn pinhole camera.
abstract interface class ManualViewIo {
  Future<List<ArRay?>> rays(List<(double, double)> points);

  /// AR-world points → view points, given the model transform the engine
  /// was last sent ([arFromTile]; the live engine projects tile points
  /// through its own copy of it).
  Future<List<(double, double, bool)?>> project(List<Vec3> worldAr, Mat4 arFromTile);
  Future<ArPlanes> planes();

  /// A native corner snap under a view point, AR (x, z), or null.
  Future<Vec2?> cornerAt(double x, double y);
}

/// Tests (and only tests) swap the seam here.
final arManualIoProvider = Provider<ManualViewIo?>((ref) => null);

class _EngineIo implements ManualViewIo {
  _EngineIo(this.session);
  final ArSessionController session;

  @override
  Future<List<ArRay?>> rays(List<(double, double)> points) async {
    final e = session.engine;
    if (e == null) return [for (final _ in points) null];
    try {
      return await e.rayAt(points);
    } catch (_) {
      return [for (final _ in points) null];
    }
  }

  @override
  Future<List<(double, double, bool)?>> project(List<Vec3> worldAr, Mat4 arFromTile) async {
    final e = session.engine;
    if (e == null || worldAr.isEmpty) return [for (final _ in worldAr) null];
    final inv = arFromTile.inverse();
    try {
      return await e.projectTile([for (final w in worldAr) inv.transformPoint(w)]);
    } catch (_) {
      return [for (final _ in worldAr) null];
    }
  }

  @override
  Future<ArPlanes> planes() async {
    final e = session.engine;
    if (e == null) return ArPlanes.empty;
    try {
      return await e.planes();
    } catch (_) {
      return ArPlanes.empty;
    }
  }

  @override
  Future<Vec2?> cornerAt(double x, double y) async => (await session.detectCornerAt(x, y))?.posAr.xz;
}

/// Demo mode: a pinhole camera standing inside the sample room, and the
/// room's own walls "measured" through the demo's hidden true pose — so
/// Snap to wall and Snap corner find the right answer, as on site.
class DemoManualIo implements ManualViewIo {
  DemoManualIo({required Mat4 truth, required ModelFootprint footprint, required double width, required double height})
      : _walls = _wallsOf(truth, footprint),
        _floorY = truth.transformPoint(footprint.pivotTile).y,
        camera = PinholeCamera.lookingAt(
          truth.transformPoint(footprint.pivotTile + const Vec3(0.3, 1.5, 1.2)),
          truth.transformPoint(footprint.pivotTile + const Vec3(0.3, 0, -0.6)),
          width: width,
          height: height,
        );

  final PinholeCamera camera;
  final List<ArPlane> _walls;
  final double _floorY;

  static List<ArPlane> _wallsOf(Mat4 truth, ModelFootprint fp) {
    final centre = fp.pivotTile.xz;
    final out = <ArPlane>[];
    for (var i = 0; i < fp.outline.length; i++) {
      final a = fp.outline[i], b = fp.outline[(i + 1) % fp.outline.length];
      final d = b - a;
      if (d.length < 0.3) continue;
      final dir = d.normalized;
      var n = Vec2(-dir.y, dir.x);
      if ((centre - (a + b) * 0.5).dot(n) < 0) n = -n;
      final mid = (a + b) * 0.5;
      out.add(ArPlane(
        id: 'demo-wall-$i',
        kind: 'wall',
        centerAr: truth.transformPoint(Vec3(mid.x, fp.floorTileY + 1.2, mid.y)),
        normalAr: truth.transformDir(Vec3(n.x, 0, n.y)),
        segment: (truth.transformPoint(fp.tile(a)).xz, truth.transformPoint(fp.tile(b)).xz),
        widthM: d.length,
        heightM: 2.4,
      ));
    }
    return out;
  }

  @override
  Future<List<ArRay?>> rays(List<(double, double)> points) async => [for (final (x, y) in points) camera.ray(x, y)];

  @override
  Future<List<(double, double, bool)?>> project(List<Vec3> worldAr, Mat4 arFromTile) async =>
      [for (final w in worldAr) camera.project(w)];

  @override
  Future<ArPlanes> planes() async => ArPlanes(floorY: _floorY, planes: _walls);

  @override
  Future<Vec2?> cornerAt(double x, double y) async => null;
}

/// Panels above the tool bar (one at a time).
enum ManualPanel { none, nudge, height, more }

/// Nudge pad buttons.
enum ManualNudge { left, right, away, toward, turnLeft, turnRight, up, down }

/// Where things are on screen right now (logical px), for the Flutter-drawn
/// outline, centre puck and handles.
class ManualScreen {
  const ManualScreen({
    this.outline = const [],
    this.pivot,
    this.corners = const [],
    this.roomCorners = const [],
    this.magnet,
    this.pinned,
  });

  final List<(double, double, bool)?> outline;
  final (double, double, bool)? pivot;
  final List<(double, double, bool)?> corners;
  final List<(double, double, bool)?> roomCorners;
  final (double, double, bool)? magnet;
  final (double, double, bool)? pinned;
}

class ArManualPlaceState {
  const ArManualPlaceState({
    this.active = false,
    this.pose,
    this.footprint,
    this.fine = false,
    this.canUndo = false,
    this.canRedo = false,
    this.panel = ManualPanel.none,
    this.cornerMode = false,
    this.stretchOn = false,
    this.grabbedCorner,
    this.pinnedCorner,
    this.magnetTarget,
    this.walls = const [],
    this.roomCorners = const [],
    this.floorKnown = false,
    this.screen = const ManualScreen(),
    this.moved = false,
    this.turned = false,
    this.sized = false,
    this.snapSeq = 0,
    this.lockSeq = 0,
    this.lastSize,
    this.cornerFailures = 0,
    this.locking = false,
    this.refineDismissed = false,
    this.loadYawRad = 0,
  });

  final bool active;

  /// Null until the camera and a floor guess are known (coach: "Point at
  /// the floor").
  final ManualPose? pose;
  final ModelFootprint? footprint;

  /// Long-press: every gesture at a quarter speed.
  final bool fine;
  final bool canUndo;
  final bool canRedo;
  final ManualPanel panel;

  /// "Snap corner" tool: corner handles and the room's corners show, and a
  /// drag that starts on a handle moves that corner.
  final bool cornerMode;

  /// "Stretch to fit" (behind More, off by default).
  final bool stretchOn;

  /// The handle being dragged, index into [ModelFootprint.corners].
  final int? grabbedCorner;

  /// A model corner snapped onto a room corner: pinches and twists keep it
  /// in place, so the model grows out from that corner. Tile (x, z).
  final Vec2? pinnedCorner;

  /// The room corner the dragged corner would land on, AR (x, z).
  final Vec2? magnetTarget;
  final List<ArPlane> walls;
  final List<Vec2> roomCorners;

  /// The engine reported a floor (the model stands on it); false = a
  /// standing-height guess.
  final bool floorKnown;
  final ManualScreen screen;

  // Coach progress.
  final bool moved;
  final bool turned;
  final bool sized;

  /// Bumped on every snap (haptic tick) and on lock.
  final int snapSeq;
  final int lockSeq;

  /// The size this floor was last locked at, for "Last time: 112 %".
  final ({double scale, double stretchX, double stretchZ, double heightM})? lastSize;

  /// Corner attempts that failed this session (the chooser then suggests
  /// "Place by hand" first, [ManualAdvice]).
  final int cornerFailures;
  final bool locking;

  /// The workspace's "Refine with a corner" banner was closed.
  final bool refineDismissed;

  /// The heading the model was loaded at: the readout's "Rot" counts from it.
  final double loadYawRad;

  /// Degrees turned since loading, 0–359.
  int get rotationDeg {
    final p = pose;
    if (p == null) return 0;
    return ((radToDeg(wrapAngle(p.yawRad - loadYawRad)) % 360 + 360) % 360).round() % 360;
  }

  ManualCoachStep get coach => cornerMode && pose != null
      ? ManualCoachStep.lock // the corner tool has its own line, see [coachKey]
      : ManualCoach.step(placed: pose != null, moved: moved, turned: turned, sized: sized);

  String get coachKey => cornerMode && pose != null
      ? (pinnedCorner == null ? 'ar.manual.coach.corner' : 'ar.manual.coach.corner_pinned')
      : ManualCoach.key(coach);

  bool get notTrueSize => pose != null && !pose!.isTrueSize;

  ArManualPlaceState copyWith({
    bool? active,
    ManualPose? pose,
    ModelFootprint? footprint,
    bool? fine,
    bool? canUndo,
    bool? canRedo,
    ManualPanel? panel,
    bool? cornerMode,
    bool? stretchOn,
    int? grabbedCorner,
    bool clearGrabbed = false,
    Vec2? pinnedCorner,
    bool clearPinned = false,
    Vec2? magnetTarget,
    bool clearMagnet = false,
    List<ArPlane>? walls,
    List<Vec2>? roomCorners,
    bool? floorKnown,
    ManualScreen? screen,
    bool? moved,
    bool? turned,
    bool? sized,
    int? snapSeq,
    int? lockSeq,
    ({double scale, double stretchX, double stretchZ, double heightM})? lastSize,
    int? cornerFailures,
    bool? locking,
    bool? refineDismissed,
    double? loadYawRad,
  }) =>
      ArManualPlaceState(
        active: active ?? this.active,
        pose: pose ?? this.pose,
        footprint: footprint ?? this.footprint,
        fine: fine ?? this.fine,
        canUndo: canUndo ?? this.canUndo,
        canRedo: canRedo ?? this.canRedo,
        panel: panel ?? this.panel,
        cornerMode: cornerMode ?? this.cornerMode,
        stretchOn: stretchOn ?? this.stretchOn,
        grabbedCorner: clearGrabbed ? null : (grabbedCorner ?? this.grabbedCorner),
        pinnedCorner: clearPinned ? null : (pinnedCorner ?? this.pinnedCorner),
        magnetTarget: clearMagnet ? null : (magnetTarget ?? this.magnetTarget),
        walls: walls ?? this.walls,
        roomCorners: roomCorners ?? this.roomCorners,
        floorKnown: floorKnown ?? this.floorKnown,
        screen: screen ?? this.screen,
        moved: moved ?? this.moved,
        turned: turned ?? this.turned,
        sized: sized ?? this.sized,
        snapSeq: snapSeq ?? this.snapSeq,
        lockSeq: lockSeq ?? this.lockSeq,
        lastSize: lastSize ?? this.lastSize,
        cornerFailures: cornerFailures ?? this.cornerFailures,
        locking: locking ?? this.locking,
        refineDismissed: refineDismissed ?? this.refineDismissed,
        loadYawRad: loadYawRad ?? this.loadYawRad,
      );
}

class ArManualPlaceController extends AutoDisposeNotifier<ArManualPlaceState> {
  /// Model opacity while it is being placed: see-through, so the real walls
  /// show behind it.
  static const previewOpacity = 0.55;

  /// The point the first placement aims through (a bit below the middle,
  /// where a held phone looks at the floor ahead).
  static const aimFraction = (0.5, 0.58);

  static const _sizeKeyPrefix = 'manual:size:';
  static const _methodKeyPrefix = 'manual:method:';

  final _undo = UndoStack<ManualPose>();
  ManualViewIo? _io;
  Timer? _projectTimer;
  Timer? _planesTimer;
  var _disposed = false;
  var _projectBusy = false;
  var _planesBusy = false;
  var _hot = false;

  /// The pose the model was loaded at (double-tap resets to it).
  ManualPose? _startPose;

  /// This session's last placement (locked or left), restored when the
  /// user comes back to "Place by hand" in the same AR session.
  ManualPose? _sessionPose;
  String? _sessionFloorId;

  /// Asked for before the floor pack arrived (route `method=manual`, or the
  /// remembered choice): begins as soon as it can.
  var _wantStart = false;
  String? _autoCheckedFloor;

  // ---- live preview push (one in flight, at most one per frame)
  var _pushing = false;
  var _pushPending = false;
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  static const _frame = Duration(milliseconds: 16);

  // ---- one-finger drag
  ManualPose? _gStart;
  (double, double)? _gStartPoint;
  Vec3? _hitStart;
  (double, double)? _pendingPoint;
  (double, double)? _lastPoint;
  var _rayBusy = false;
  Completer<void>? _rayIdle;

  // ---- two fingers
  var _two = TwoFingerMode.undecided;
  var _wasYawSnapped = false;

  // ---- height slider / stretch slider drag start
  ManualPose? _sliderStart;

  var _afterTurnActions = 0;

  // ---- corner failure counting (chooser advice)
  DateTime _lastNotFoundAt = DateTime.fromMillisecondsSinceEpoch(0);

  ArSessionController get _session => ref.read(arSessionProvider.notifier);
  ArSessionState get _s => ref.read(arSessionProvider);

  @override
  ArManualPlaceState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _stopTimers();
    });
    ref.listen<ArSessionState>(arSessionProvider, _onSession);
    ref.listen<ArSetupState>(arSetupProvider, (prev, next) {
      // Corner attempts that went wrong: a mismatch, or plain walls the
      // phone can't see. Two of them and the chooser suggests this method.
      final mismatch = next.step == ArSetupStep.mismatch && prev?.step != ArSetupStep.mismatch;
      final noWalls = next.wallsMissing && !(prev?.wallsMissing ?? false);
      if (mismatch || noWalls) _countFailure();
    });
    return const ArManualPlaceState();
  }

  void _set(ArManualPlaceState next) {
    if (_disposed) return;
    state = next;
  }

  void _countFailure() => _set(state.copyWith(cornerFailures: state.cornerFailures + 1));

  void _onSession(ArSessionState? prev, ArSessionState next) {
    // "No corner here" while aiming, at most once per 10 s: one failed try.
    if (next.coachSeq != prev?.coachSeq && next.coachCode == 'corner-not-found') {
      final now = DateTime.now();
      if (now.difference(_lastNotFoundAt) > const Duration(seconds: 10)) {
        _lastNotFoundAt = now;
        _countFailure();
      }
    }
    if (next.phase == ArSessionPhase.checking && prev?.phase != ArSessionPhase.checking) {
      // The session (re)started: a new AR world, so a pose from the old one
      // means nothing any more.
      _sessionPose = null;
      _autoCheckedFloor = null;
    }
    final floor = next.floor;
    if (floor != null && _sessionFloorId != floor.floorId) {
      // A new floor pack (or a restarted session): nothing carries over.
      _sessionFloorId = floor.floorId;
      _sessionPose = null;
      _autoCheckedFloor = null;
    }
    if (next.phase == ArSessionPhase.running && floor != null && next.stage == ArSessionStage.setup && !state.active) {
      if (_wantStart) {
        _wantStart = false;
        unawaited(begin());
      } else if (_autoCheckedFloor != floor.floorId && !next.isPlaced && next.args?.focusCode == null) {
        _autoCheckedFloor = floor.floorId;
        unawaited(_maybeAutoBegin(floor.floorId));
      }
    }
    if (state.active) {
      if (prev?.plan == null && next.plan != null) _rebuildFootprint();
      if (prev?.paused != next.paused || prev?.thermalStatus != next.thermalStatus) _restartTimers();
      if (next.stage != ArSessionStage.setup || next.phase != ArSessionPhase.running) {
        // Left setup some other way (a restart, a board scan): stop quietly,
        // and give the session back its own transform pushes.
        _stopTimers();
        // (A restart is a new AR world: its pose was dropped above.)
        if (next.phase == ArSessionPhase.running) _sessionPose = state.pose ?? _sessionPose;
        _set(state.copyWith(active: false, panel: ManualPanel.none, cornerMode: false));
        if (_session.manualPreviewing) unawaited(_session.endManualPreview());
      }
    }
  }

  /// The remembered choice for this floor was "Place by hand".
  Future<void> _maybeAutoBegin(String floorId) async {
    String? v;
    try {
      v = await ref.read(arPackStoreProvider).getArPref('$_methodKeyPrefix$floorId');
    } catch (_) {
      return; // no store (a widget test)
    }
    if (_disposed || v != '1' || state.active) return;
    await begin();
  }

  /// Route `method=manual`: start as soon as the session can.
  void requestStart() {
    final s = _s;
    if (s.phase == ArSessionPhase.running && s.floor != null) {
      unawaited(begin());
    } else {
      _wantStart = true;
    }
  }

  /// The chooser's "Place by hand" tile. With "Remember my choice" the
  /// floor opens straight into it next time (its own pref key, so the
  /// corner/board remembered method is simply cleared, not overwritten).
  Future<void> chooseFromChooser({required bool remember}) async {
    final floor = _s.floor;
    if (floor != null) {
      try {
        await ref.read(arPackStoreProvider).setArPref('$_methodKeyPrefix${floor.floorId}', remember ? '1' : null);
      } catch (_) {}
      if (remember) await ref.read(arPrefsProvider.notifier).rememberMethod(floor.floorId, null);
    }
    await begin();
  }

  // ------------------------------------------------------------- lifecycle

  Future<void> begin() async {
    final s = _s;
    final floor = s.floor;
    if (s.phase != ArSessionPhase.running || floor == null) {
      _wantStart = true;
      return;
    }
    if (state.active) return;
    final fp = _footprintFor(s);
    _io = ref.read(arManualIoProvider) ??
        (s.demo
            ? DemoManualIo(
                truth: _session.director?.trueArFromTile ?? Mat4.identity(),
                footprint: fp,
                width: _session.viewSize.width,
                height: _session.viewSize.height,
              )
            : _EngineIo(_session));
    _undo.clear();
    _session.beginManualPreview();
    unawaited(_session.setLayers(mep: true, structure: true, architecture: true, opacity: previewOpacity));
    _set(ArManualPlaceState(
      active: true,
      footprint: fp,
      cornerFailures: state.cornerFailures,
      refineDismissed: state.refineDismissed,
    ));
    unawaited(_loadLastSize(floor.floorId));
    _restartTimers();
    await _refreshPlanes();
    if (_disposed || !state.active) return;
    final restored = _sessionPose;
    if (restored != null) {
      _startPose = restored;
      _applyPose(restored, push: true);
      _set(state.copyWith(moved: true, turned: true, sized: true, loadYawRad: restored.yawRad));
    } else {
      await _placeInitial();
    }
  }

  /// First placement: [ManualLimits.loadDistanceM] ahead on the floor.
  /// Retried by the planes timer until the camera is known.
  Future<void> _placeInitial() async {
    final io = _io;
    final fp = state.footprint;
    if (io == null || fp == null || state.pose != null) return;
    final size = _session.viewSize;
    final rays = await io.rays([(size.width * aimFraction.$1, size.height * aimFraction.$2)]);
    if (_disposed || !state.active || state.pose != null) return;
    final ray = rays.isEmpty ? null : rays.first;
    final s = _s;
    final cam = ray?.originAr ?? s.cameraAr;
    final fwd = ray?.dirAr ?? s.cameraForwardAr;
    if (cam == null || fwd == null) return; // not tracking yet: the coach says so
    final floorY = _floorY();
    final pose = ManualGestures.initialPose(
      cameraAr: cam,
      forwardAr: fwd,
      floorY: floorY,
      modelMainHeading: fp.mainHeadingRad,
      walls: state.walls,
    );
    _startPose = pose;
    _set(state.copyWith(loadYawRad: pose.yawRad));
    _applyPose(pose, push: true);
  }

  double? _floorY() => state.floorKnown ? _floorFromPlanes : _session.floorAr;
  double? _floorFromPlanes;

  /// "Other method" / Back: the session's own fit (or nothing) shows again.
  Future<void> cancel() async {
    if (!state.active) return;
    _sessionPose = state.pose ?? _sessionPose;
    _stopTimers();
    _set(state.copyWith(active: false, panel: ManualPanel.none, cornerMode: false, clearGrabbed: true, clearMagnet: true));
    await _session.endManualPreview();
  }

  /// "Lock placement": the pose becomes the session's fit (amber "Placed by
  /// hand", anchored), the size is remembered for this floor, and the
  /// workspace opens as after a corner placement.
  Future<bool> lock() async {
    final pose = state.pose;
    final fp = state.footprint;
    if (!state.active || pose == null || fp == null || state.locking) return false;
    _set(state.copyWith(locking: true));
    final fit = await _session.applyManualPlacement(ManualPlacement(pose: pose, pivotTile: fp.pivotTile));
    if (_disposed) return false;
    _sessionPose = pose;
    final floor = _s.floor;
    if (floor != null) {
      try {
        await ref.read(arPackStoreProvider).setArPref('$_sizeKeyPrefix${floor.floorId}', jsonEncode(pose.sizeJson()));
      } catch (_) {}
    }
    _stopTimers();
    _set(state.copyWith(
      active: false,
      locking: false,
      panel: ManualPanel.none,
      cornerMode: false,
      clearGrabbed: true,
      clearMagnet: true,
      lockSeq: state.lockSeq + 1,
      refineDismissed: false,
    ));
    if (fit.quality == AlignmentQuality.none) return false;
    _session.enterWorkspace();
    _session.toast(pose.isTrueSize ? 'ar.manual.locked_toast' : 'ar.manual.locked_toast_scaled');
    return true;
  }

  /// The workspace banner's "Refine with a corner": snap one real corner
  /// with the hand placement as the starting guess (the setup's own
  /// re-snap); the measured corner then replaces the hand fit.
  void refineWithCorner() {
    _set(state.copyWith(refineDismissed: true));
    ref.read(arSetupProvider.notifier).reSnap();
  }

  void dismissRefine() => _set(state.copyWith(refineDismissed: true));

  // ------------------------------------------------------------ footprint

  ModelFootprint _footprintFor(ArSessionState s) {
    final floor = s.floor!;
    final plan = s.plan;
    final floorTileY = floor.floorDatumY + floor.floorFinishOffsetM;
    List<Vec2>? room;
    if (plan != null && plan.spaces.isNotEmpty) {
      ArPlanSpace? pick;
      final name = s.args?.spaceName?.trim().toLowerCase();
      if (name != null && name.isNotEmpty) {
        for (final sp in plan.spaces) {
          if (sp.name.toLowerCase().contains(name)) {
            pick = sp;
            break;
          }
        }
      }
      final t = s.target;
      if (pick == null && t != null) pick = plan.spaceAt(t.centre.x, t.centre.z);
      if (pick == null) {
        var best = 0.0;
        for (final sp in plan.spaces) {
          final a = _area(sp.polygon);
          if (a > best) {
            best = a;
            pick = sp;
          }
        }
      }
      if (pick != null && pick.polygon.length >= 3) room = pick.polygon;
    }
    var walls = plan?.walls ?? const <List<Vec2>>[];
    var thick = plan?.wallThicknesses ?? const <double>[];
    if (room != null && plan != null) {
      // Only the walls around this room: snapping to a wall three rooms
      // away would be a wrong answer that looks right.
      var lo = room.first, hi = room.first;
      for (final p in room) {
        lo = Vec2(math.min(lo.x, p.x), math.min(lo.y, p.y));
        hi = Vec2(math.max(hi.x, p.x), math.max(hi.y, p.y));
      }
      bool near(Vec2 p) => p.x >= lo.x - 0.6 && p.x <= hi.x + 0.6 && p.y >= lo.y - 0.6 && p.y <= hi.y + 0.6;
      final keptWalls = <List<Vec2>>[];
      final keptThick = <double>[];
      for (var i = 0; i < walls.length; i++) {
        if (walls[i].any(near)) {
          keptWalls.add(walls[i]);
          keptThick.add(plan.wallThicknessAt(i));
        }
      }
      walls = keptWalls;
      thick = keptThick;
    }
    return ModelFootprint.build(
      floorTileY: floorTileY,
      room: room,
      bounds: plan == null ? null : (Vec2(plan.minX, plan.minZ), Vec2(plan.maxX, plan.maxZ)),
      walls: walls,
      thicknesses: thick,
      modelCorners: [for (final c in floor.corners) (c.posTile.xz, c.faceA, c.faceB, c.kind)],
    );
  }

  static double _area(List<Vec2> poly) {
    var a = 0.0;
    for (var i = 0; i < poly.length; i++) {
      final p = poly[i], q = poly[(i + 1) % poly.length];
      a += p.x * q.y - q.x * p.y;
    }
    return a.abs() / 2;
  }

  /// The plan arrived after the model was loaded: a better footprint, with
  /// the pose re-expressed about the new pivot so nothing jumps.
  void _rebuildFootprint() {
    final old = state.footprint;
    final pose = state.pose;
    final fp = _footprintFor(_s);
    if (old == null || pose == null) {
      _set(state.copyWith(footprint: fp));
      return;
    }
    final w = pose.arFromTile(old.pivotTile).transformPoint(fp.pivotTile);
    final moved = pose.copyWith(pos: w.xz);
    final sp = _startPose;
    if (sp != null) _startPose = sp.copyWith(pos: sp.arFromTile(old.pivotTile).transformPoint(fp.pivotTile).xz);
    _undo.clear();
    _set(state.copyWith(footprint: fp, pose: moved, canUndo: false, canRedo: false, clearPinned: true));
    _schedulePush();
  }

  Future<void> _loadLastSize(String floorId) async {
    try {
      final raw = await ref.read(arPackStoreProvider).getArPref('$_sizeKeyPrefix$floorId');
      if (raw == null || _disposed) return;
      final size = ManualPose.sizeFromJson(jsonDecode(raw));
      // Only worth offering when it differs from true size.
      if (size != null && ((size.scale - 1).abs() >= 0.005 || (size.stretchX - 1).abs() >= 0.005 || (size.stretchZ - 1).abs() >= 0.005)) {
        _set(state.copyWith(lastSize: size));
      }
    } catch (_) {}
  }

  // --------------------------------------------------------------- timers

  void _restartTimers() {
    _stopTimers();
    if (!state.active || _s.paused) return;
    // Power/thermal: half the rate once the phone runs warm.
    _hot = _s.thermalStatus >= 2;
    _projectTimer = Timer.periodic(Duration(milliseconds: _hot ? 133 : 66), (_) => unawaited(_project()));
    _planesTimer = Timer.periodic(Duration(milliseconds: _hot ? 2000 : 1000), (_) => unawaited(_refreshPlanes()));
  }

  void _stopTimers() {
    _projectTimer?.cancel();
    _projectTimer = null;
    _planesTimer?.cancel();
    _planesTimer = null;
  }

  Future<void> _refreshPlanes() async {
    final io = _io;
    if (io == null || _planesBusy || !state.active) return;
    _planesBusy = true;
    try {
      final p = await io.planes();
      if (_disposed || !state.active) return;
      final walls = p.walls;
      final floorY = p.floorY ?? _session.floorAr;
      var next = state.copyWith(walls: walls, roomCorners: ManualSnaps.roomCorners(walls));
      if (floorY != null) {
        _floorFromPlanes = floorY;
        next = next.copyWith(floorKnown: true);
        // The model was standing on a guessed floor: put it on the real one.
        final pose = next.pose;
        if (pose != null && (pose.floorY - floorY).abs() > 0.005) {
          next = next.copyWith(pose: pose.copyWith(floorY: floorY));
          _startPose = _startPose?.copyWith(floorY: floorY);
          _set(next);
          _schedulePush();
        }
      }
      _set(next);
      if (state.pose == null) await _placeInitial();
    } finally {
      _planesBusy = false;
    }
  }

  Future<void> _project() async {
    final io = _io;
    final pose = state.pose;
    final fp = state.footprint;
    if (io == null || pose == null || fp == null || _projectBusy || !state.active) return;
    _projectBusy = true;
    try {
      final m = pose.arFromTile(fp.pivotTile);
      final outline = [for (final p in fp.outline) m.transformPoint(fp.tile(p))];
      final corners = state.cornerMode ? [for (final p in fp.corners) m.transformPoint(fp.tile(p))] : const <Vec3>[];
      final floorY = pose.floorY + pose.heightM;
      final rooms = state.cornerMode ? [for (final c in state.roomCorners) Vec3(c.x, floorY, c.y)] : const <Vec3>[];
      final magnet = state.magnetTarget;
      final pinned = state.pinnedCorner;
      final pts = <Vec3>[
        ...outline,
        pose.pivotAr,
        ...corners,
        ...rooms,
        if (magnet != null) Vec3(magnet.x, floorY, magnet.y),
        if (pinned != null) m.transformPoint(fp.tile(pinned)),
      ];
      final r = await io.project(pts, m);
      if (_disposed || !state.active || r.length != pts.length) return;
      var i = 0;
      List<(double, double, bool)?> take(int n) {
        final out = r.sublist(i, i + n);
        i += n;
        return out;
      }

      final screen = ManualScreen(
        outline: take(outline.length),
        pivot: take(1).first,
        corners: take(corners.length),
        roomCorners: take(rooms.length),
        magnet: magnet != null ? take(1).first : null,
        pinned: pinned != null ? take(1).first : null,
      );
      _set(state.copyWith(screen: screen));
    } finally {
      _projectBusy = false;
    }
  }

  // ------------------------------------------------------------- applying

  /// Sets the pose ([record] puts [before] (default: the current pose) on
  /// the undo stack first) and sends it to the engine, throttled.
  void _applyPose(ManualPose p, {bool record = false, ManualPose? before, bool push = true}) {
    final prev = before ?? state.pose;
    if (record && prev != null && prev != p) _undo.record(prev);
    _set(state.copyWith(pose: p, canUndo: _undo.canUndo, canRedo: _undo.canRedo));
    if (push) _schedulePush();
    unawaited(_project());
  }

  void _schedulePush() {
    _pushPending = true;
    if (!_pushing) unawaited(_drainPush());
  }

  /// One transform in flight, at most one a frame; the newest pose wins.
  Future<void> _drainPush() async {
    _pushing = true;
    try {
      while (_pushPending && !_disposed && state.active) {
        _pushPending = false;
        final since = DateTime.now().difference(_lastPush);
        if (since < _frame) await Future<void>.delayed(_frame - since);
        final p = state.pose;
        final fp = state.footprint;
        if (p == null || fp == null || _disposed || !state.active) break;
        _lastPush = DateTime.now();
        await _session.previewModelTransform(p.arFromTile(fp.pivotTile));
      }
    } finally {
      _pushing = false;
    }
  }

  /// Marks coach progress. Any action after the twist step counts as "the
  /// size was looked at" (the pinch line is advice, not a gate).
  void _progress({bool moved = false, bool turned = false, bool sized = false}) {
    if (state.turned && !sized) _afterTurnActions++;
    _set(state.copyWith(
      moved: state.moved || moved,
      turned: state.turned || turned,
      sized: state.sized || sized || (state.turned && _afterTurnActions >= 2),
    ));
  }

  // ---------------------------------------------------- one-finger drag

  /// A drag starts at view point ([x], [y]). [corner] is the handle under
  /// the finger in the corner tool.
  void moveStart(double x, double y, {int? corner}) {
    final pose = state.pose;
    if (!state.active || pose == null) return;
    _gStart = pose;
    _gStartPoint = (x, y);
    _hitStart = null;
    _pendingPoint = null;
    _lastPoint = (x, y);
    _set(state.copyWith(grabbedCorner: corner, clearGrabbed: corner == null, clearMagnet: true));
  }

  void moveUpdate(double x, double y) {
    if (_gStart == null) return;
    _pendingPoint = (x, y);
    _lastPoint = (x, y);
    if (!_rayBusy) unawaited(_pumpRays());
  }

  Future<void> _pumpRays() async {
    final io = _io;
    if (io == null || _rayBusy) return;
    _rayBusy = true;
    _rayIdle = Completer<void>();
    try {
      while (_pendingPoint != null && _gStart != null) {
        final start = _gStart!;
        final pt = _pendingPoint!;
        _pendingPoint = null;
        final needStart = _hitStart == null;
        final rays = await io.rays([if (needStart) _gStartPoint!, pt]);
        if (_disposed || _gStart == null || rays.isEmpty) break;
        final planeY = start.floorY + start.heightM;
        if (needStart) {
          final r0 = rays.first;
          _hitStart = r0 == null ? null : ManualGestures.floorHit(r0, planeY);
          if (_hitStart == null) continue;
        }
        final r = rays.last;
        final hit = r == null ? null : ManualGestures.floorHit(r, planeY);
        if (hit == null) continue;
        final p = ManualGestures.dragged(start, _hitStart!, hit, fine: state.fine);
        Vec2? magnet;
        final ci = state.grabbedCorner;
        final fp = state.footprint;
        if (ci != null && fp != null && ci < fp.corners.length) {
          final c = p.arFromTile(fp.pivotTile).transformPoint(fp.tile(fp.corners[ci])).xz;
          magnet = ManualSnaps.magnet(c, state.roomCorners);
        }
        _set(state.copyWith(magnetTarget: magnet, clearMagnet: magnet == null));
        _applyPose(p);
      }
    } finally {
      _rayBusy = false;
      _rayIdle?.complete();
      _rayIdle = null;
    }
  }

  Future<void> moveEnd() async {
    final start = _gStart;
    if (start == null) return;
    if (_rayBusy) await _rayIdle?.future;
    _gStart = null;
    final ci = state.grabbedCorner;
    final fp = state.footprint;
    var pose = state.pose;
    if (pose == null || fp == null) return;
    if (ci != null && ci < fp.corners.length) {
      // Snap corner: land on the nearest room corner within the magnet
      // radius — the walls' crossing, or what the engine snaps under the
      // finger right now.
      final c = pose.arFromTile(fp.pivotTile).transformPoint(fp.tile(fp.corners[ci])).xz;
      final candidates = [...state.roomCorners];
      final last = _lastPoint;
      if (last != null) {
        final native = await _io?.cornerAt(last.$1, last.$2);
        if (native != null) candidates.add(native);
      }
      if (_disposed) return;
      final target = ManualSnaps.magnet(c, candidates);
      if (target != null) {
        pose = pose.copyWith(pos: pose.pos + (target - c));
        _set(state.copyWith(pinnedCorner: fp.corners[ci], snapSeq: state.snapSeq + 1));
        _session.toast('ar.manual.corner_snapped');
      } else if (pose != start) {
        _session.toast('ar.manual.corner_no_match', tone: ArToastTone.warning);
      }
      _applyPose(pose, record: true, before: start);
      _set(state.copyWith(clearGrabbed: true, clearMagnet: true));
      if (pose != start) _progress(moved: true);
      return;
    }
    if (pose != start) {
      _applyPose(pose, record: true, before: start);
      // Moving the whole model lets go of a pinned corner.
      _set(state.copyWith(clearPinned: true, clearGrabbed: true));
      _progress(moved: true);
    }
  }

  // ------------------------------------------------------------ two fingers

  void twoStart() {
    if (!state.active || state.pose == null) return;
    // A second finger landing mid-drag ends the drag where it is.
    if (_gStart != null) {
      final s = _gStart!;
      _gStart = null;
      _pendingPoint = null;
      if (state.pose != s) _undo.record(s);
    }
    _gStart = null;
    _sliderStart = state.pose;
    _two = TwoFingerMode.undecided;
    _wasYawSnapped = false;
  }

  /// [rotationRad] and [scale] since the gesture began; [dxPx]/[dyPx] the
  /// focal point's total movement.
  void twoUpdate({required double rotationRad, required double scale, required double dxPx, required double dyPx}) {
    final start = _sliderStart;
    final fp = state.footprint;
    if (start == null || fp == null || !state.active) return;
    if (_two == TwoFingerMode.undecided) {
      _two = TwoFingerClassifier.classify(rotationRad: rotationRad, scale: scale, dxPx: dxPx, dyPx: dyPx);
      if (_two == TwoFingerMode.undecided) return;
    }
    ManualPose p;
    if (_two == TwoFingerMode.height) {
      p = start.copyWith(heightM: ManualGestures.heightDragged(start.heightM, dyPx, fine: state.fine));
    } else {
      final yaw = ManualGestures.twisted(start.yawRad, rotationRad, fine: state.fine);
      final snap = ManualGestures.softSnapYaw(yaw, _alignedYaws(fp, start));
      if (snap.snapped && !_wasYawSnapped) _set(state.copyWith(snapSeq: state.snapSeq + 1));
      _wasYawSnapped = snap.snapped;
      final s = ManualGestures.pinched(start.scale, scale, fine: state.fine);
      p = start.copyWith(yawRad: snap.yaw, scale: s);
      final pin = state.pinnedCorner;
      if (pin != null) p = ManualGestures.keepFixed(start, p, fp.tile(pin), fp.pivotTile);
    }
    _applyPose(p);
  }

  void twoEnd() {
    final start = _sliderStart;
    _sliderStart = null;
    final pose = state.pose;
    if (start == null || pose == null) return;
    if (pose == start) return;
    _undo.record(start);
    _set(state.copyWith(canUndo: _undo.canUndo, canRedo: _undo.canRedo));
    _progress(
      turned: (wrapAngle(pose.yawRad - start.yawRad)).abs() > degToRad(1),
      sized: (pose.scale - start.scale).abs() > 1e-6,
    );
  }

  /// Model-wall headings the twist clicks onto: the detected walls, or —
  /// before any wall is measured — the heading it was loaded with.
  List<double> _alignedYaws(ModelFootprint fp, ManualPose pose) {
    final w = ManualGestures.wallAlignedYaws(fp.mainHeadingRad, state.walls);
    if (w.isNotEmpty) return w;
    final s = _startPose;
    return s == null ? const [] : [s.yawRad];
  }

  // ---------------------------------------------------------------- tools

  void toggleFine() {
    _set(state.copyWith(fine: !state.fine));
    _session.toast(state.fine ? 'ar.manual.fine_on' : 'ar.manual.fine_off');
  }

  /// Double-tap: back to where the model was loaded (undoable).
  void reset() {
    final s = _startPose;
    final pose = state.pose;
    if (s == null || pose == null || s == pose) return;
    _applyPose(s.copyWith(floorY: pose.floorY), record: true);
    _set(state.copyWith(clearPinned: true));
    _session.toast('ar.manual.reset_done');
  }

  void undo() {
    final pose = state.pose;
    if (pose == null) return;
    final back = _undo.undo(pose);
    if (back == null) return;
    _applyPose(back);
    _set(state.copyWith(canUndo: _undo.canUndo, canRedo: _undo.canRedo));
  }

  void redo() {
    final pose = state.pose;
    if (pose == null) return;
    final fwd = _undo.redo(pose);
    if (fwd == null) return;
    _applyPose(fwd);
    _set(state.copyWith(canUndo: _undo.canUndo, canRedo: _undo.canRedo));
  }

  /// "Snap to wall".
  void snapToWall() {
    final pose = state.pose;
    final fp = state.footprint;
    if (pose == null || fp == null) return;
    final snap = ManualSnaps.snapToWall(pose, fp, state.walls);
    if (snap == null) {
      _session.toast(state.walls.isEmpty ? 'ar.manual.no_wall' : 'ar.manual.no_wall_near', tone: ArToastTone.warning);
      return;
    }
    _applyPose(snap.pose, record: true);
    _set(state.copyWith(snapSeq: state.snapSeq + 1, clearPinned: true));
    _progress(moved: true, turned: true);
    _session.toast('ar.manual.snapped_wall');
  }

  void toggleCornerMode() {
    final on = !state.cornerMode;
    _set(state.copyWith(cornerMode: on, panel: ManualPanel.none, clearGrabbed: true, clearMagnet: true));
    unawaited(_project());
    if (on && state.roomCorners.isEmpty) _session.toast('ar.manual.no_room_corner');
  }

  void unpin() => _set(state.copyWith(clearPinned: true));

  void openPanel(ManualPanel p) => _set(state.copyWith(panel: state.panel == p ? ManualPanel.none : p));

  void nudge(ManualNudge n) {
    final pose = state.pose;
    if (pose == null) return;
    const m = ManualLimits.nudgeM;
    const d = ManualLimits.nudgeDeg;
    final fwd = _s.cameraForwardAr;
    final next = switch (n) {
      ManualNudge.left => ManualGestures.nudged(pose, rightM: -m, cameraForwardAr: fwd),
      ManualNudge.right => ManualGestures.nudged(pose, rightM: m, cameraForwardAr: fwd),
      ManualNudge.away => ManualGestures.nudged(pose, awayM: m, cameraForwardAr: fwd),
      ManualNudge.toward => ManualGestures.nudged(pose, awayM: -m, cameraForwardAr: fwd),
      ManualNudge.turnLeft => ManualGestures.nudged(pose, turnDeg: -d),
      ManualNudge.turnRight => ManualGestures.nudged(pose, turnDeg: d),
      ManualNudge.up => ManualGestures.nudged(pose, upM: m),
      ManualNudge.down => ManualGestures.nudged(pose, upM: -m),
    };
    var p = next;
    final pin = state.pinnedCorner;
    final fp = state.footprint;
    final turning = n == ManualNudge.turnLeft || n == ManualNudge.turnRight;
    if (turning && pin != null && fp != null) p = ManualGestures.keepFixed(pose, p, fp.tile(pin), fp.pivotTile);
    if (!turning && n != ManualNudge.up && n != ManualNudge.down) _set(state.copyWith(clearPinned: true));
    _applyPose(p, record: true);
    _progress(moved: !turning, turned: turning);
  }

  // --------------------------------------------------------- slider drags

  void sliderStart() => _sliderStart = state.pose;

  void sliderEnd() {
    final start = _sliderStart;
    _sliderStart = null;
    final pose = state.pose;
    if (start == null || pose == null || pose == start) return;
    _undo.record(start);
    _set(state.copyWith(canUndo: _undo.canUndo, canRedo: _undo.canRedo));
  }

  void setHeight(double h) {
    final pose = state.pose;
    if (pose == null) return;
    _applyPose(pose.copyWith(heightM: h.clamp(-ManualLimits.maxHeightM, ManualLimits.maxHeightM).toDouble()));
  }

  /// Turns "Stretch to fit" on or off; off puts both axes back to 1.
  void setStretchOn(bool on) {
    _set(state.copyWith(stretchOn: on));
    final pose = state.pose;
    if (!on && pose != null && pose.isStretched) _resize(pose.copyWith(stretchX: 1, stretchZ: 1), record: true);
  }

  void setStretch({double? x, double? z}) {
    final pose = state.pose;
    if (pose == null || !state.stretchOn) return;
    double c(double v) => ManualGestures.snapTrueSize(v.clamp(ManualLimits.minStretch, ManualLimits.maxStretch).toDouble());
    _resize(pose.copyWith(stretchX: x == null ? null : c(x), stretchZ: z == null ? null : c(z)));
  }

  /// One tap back to true size (uniform and stretch).
  void trueSize() {
    final pose = state.pose;
    if (pose == null || pose.isTrueSize) return;
    _resize(pose.copyWith(scale: 1, stretchX: 1, stretchZ: 1), record: true);
    _progress(sized: true);
  }

  /// "Last time: 112 %": this floor's saved size.
  void useLastSize() {
    final pose = state.pose;
    final last = state.lastSize;
    if (pose == null || last == null) return;
    if (last.stretchX != 1 || last.stretchZ != 1) _set(state.copyWith(stretchOn: true));
    _resize(pose.copyWith(scale: last.scale, stretchX: last.stretchX, stretchZ: last.stretchZ, heightM: last.heightM), record: true);
    _progress(sized: true);
  }

  /// A size change that keeps a pinned corner where it is.
  void _resize(ManualPose next, {bool record = false}) {
    final pose = state.pose;
    final fp = state.footprint;
    final pin = state.pinnedCorner;
    var p = next;
    if (pose != null && fp != null && pin != null) p = ManualGestures.keepFixed(pose, next, fp.tile(pin), fp.pivotTile);
    _applyPose(p, record: record);
  }
}

final arManualPlaceProvider = NotifierProvider.autoDispose<ArManualPlaceController, ArManualPlaceState>(
  ArManualPlaceController.new,
);

/// The method chooser's advice: suggest "Place by hand" first?
bool arManualRecommended(ArSessionState s, ArSetupState setup, int cornerFailures) {
  final floor = s.floor;
  final boardFirst = setup.recommended == ArPlaceMethod.board && (floor?.activeMarkers.isNotEmpty ?? false);
  return ManualAdvice.recommend(corners: floor?.corners.length ?? 0, cornerFailures: cornerFailures, boardFirst: boardFirst);
}
