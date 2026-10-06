import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ar/alignment_estimator.dart';
import '../core/ar/ar_engine.dart' show ArDepthPoint;
import '../core/ar/baseline_heading.dart';
import '../core/ar/corner_matcher.dart';
import '../core/ar/ghost_spot.dart';
import '../core/ar/vec.dart';
import '../core/ar/wall_fit.dart';
import '../domain/ar_models.dart' show ManifestMarker;
import 'ar_demo_gateway.dart' show DemoArGateway;
import 'ar_gateway_live.dart' show LiveArGateway;
import 'ar_prefs_controller.dart';
import 'ar_session_controller.dart';
import 'ar_view_models.dart';

/// The setup ladder (docs/ar-setup-and-gamma-parity.md §2.1): scan a board if
/// one is known, otherwise snap two corners, then leave a board so the next
/// visit is one scan. Every step feeds the same estimator through
/// [ArSessionController.addObservation]; this controller only decides what
/// the screen asks for next.
enum ArSetupStep {
  /// TabMethod / PhMethod: how to place the model.
  choose,

  /// S1: tap corner A on the mini plan.
  start,

  /// S2 / TabSnap: aim the pin at corner A.
  cornerA,

  /// S3: snap corner B, matched automatically.
  cornerB,

  /// Pointing at a board, nothing locked on yet.
  boardScan,

  /// M3: the hold-still lock ring on a known board.
  boardLock,

  /// M4: placed with one board, radar to the next.
  aligned,

  /// S4: locked; offer "Make next time one scan".
  locked,

  /// The ghost outline is up; waiting for the spare board to be scanned.
  leaveBoard,

  /// TabRegister / PhRegister / I4: "New board, not saved yet".
  register,

  /// S5: guided single-axis nudge.
  nudge,

  /// Observations disagree by more than 5 cm (§2.7 red).
  mismatch,

  /// Plain walls, no corner snap: tap each wall 3–5 times near the corner
  /// and Dart fits the corner (`wall_fit.dart`). Returns to [wallsFor].
  wallTaps,

  /// After a rough corner: tap a wall's base 2–5 m along it to fix the
  /// heading from positions (`baseline_heading.dart`). Returns to cornerB.
  baseline,
}

/// Why "Use this corner" could not place the model from corner A — shown
/// on the card in plain words, with the way out (first iPhone run
/// 2026-10-06: one vague toast, repeated, and no way forward).
enum ArCornerProblem {
  /// The snap's shape (inside vs column/outside) differs from the corner
  /// picked, and the model's nearest corner of the snapped shape is beyond
  /// [CornerMatcher.autoPickRadiusM]: tap one on the plan, or check the
  /// floor.
  otherShapeNearby,

  /// The model has no corner of the snapped shape at all: most likely not
  /// this room — offer another floor/model and the demo room.
  noneOfShape,

  /// The fit did not take (never expected with one corner; kept so the
  /// screen says something useful rather than advancing silently).
  notPlaced,
}

class ArSetupState {
  const ArSetupState({
    this.step = ArSetupStep.choose,
    this.method,
    this.recommended = ArPlaceMethod.corners,
    this.rememberChoice = false,
    this.ranked = const [],
    this.chosenA,
    this.cornerAId,
    this.snapped,
    this.snapSeq = 0,
    this.suggestedB,
    this.matchedB,
    this.ambiguousB = const [],
    this.noMatchB = false,
    this.tooCloseB = false,
    this.sighting,
    this.lockingCode,
    this.lockProgress = 0,
    this.lockSeq = 0,
    this.nextBoard,
    this.ghost,
    this.pendingCode,
    this.pendingPosTile,
    this.pendingNormalTile,
    this.pendingHeightM,
    this.pendingScalePct,
    this.pendingName,
    this.pendingIsSpare = true,
    this.otherFloorName,
    this.otherFloorCode,
    this.saving = false,
    this.savedLabel,
    this.saveError,
    this.saveQueued = false,
    this.returnToWork = false,
    this.wallsMissing = false,
    this.wallsFor,
    this.tapsA = const [],
    this.tapsB = const [],
    this.wallIndex = 0,
    this.measuring = false,
    this.cornerAMethod,
    this.baselineDone = false,
    this.cornerProblem,
    this.problemShape,
    this.problemSeq = 0,
    this.noticeKey,
    this.noticeArgs = const [],
    this.noticeSeq = 0,
  });

  final ArSetupStep step;
  final ArPlaceMethod? method;
  final ArPlaceMethod recommended;
  final bool rememberChoice;

  /// Corner A choices, best first (only the room's corners when known).
  final List<CornerCandidate> ranked;
  final CornerCandidate? chosenA;
  final String? cornerAId;

  /// The corner snapped under the pin, waiting for "Use this corner".
  final DetectedCorner? snapped;

  /// Bumped on every new snap — the screen buzzes once per snap.
  final int snapSeq;
  final CornerCandidate? suggestedB;
  final CornerCandidate? matchedB;

  /// Two candidates within 1 m: ask with two big buttons (§2.4).
  final List<CornerMatch> ambiguousB;
  final bool noMatchB;

  /// B is too close to A to fix the heading (< 3 m).
  final bool tooCloseB;

  /// The latest board sighting (coaching chips read it).
  final ArMarkerSighting? sighting;
  final String? lockingCode;
  final double lockProgress;

  /// Bumped when a board locks — the screen gives the lock haptic.
  final int lockSeq;

  /// M4's "scan one more board": the best second board.
  final ArMarkerInfo? nextBoard;

  /// Where "leave a board" suggests sticking the spare (§2.5).
  final ArPinSpec? ghost;

  final String? pendingCode;
  final Vec3? pendingPosTile;
  final Vec3? pendingNormalTile;
  final double? pendingHeightM;
  final double? pendingScalePct;
  final String? pendingName;

  /// A true spare (bindable) vs a board the server doesn't know at all.
  final bool pendingIsSpare;
  final String? otherFloorName;
  final String? otherFloorCode;
  final bool saving;
  final String? savedLabel;
  final String? saveError;
  final bool saveQueued;

  /// Setup was re-opened from the workspace (Re-snap, Save a board here,
  /// Fine-tune): finishing goes back to work instead of the next step.
  final bool returnToWork;

  /// The engine said `corner-no-walls` while aiming: offer the wall taps.
  final bool wallsMissing;

  /// The corner step the wall taps belong to (and return to).
  final ArSetupStep? wallsFor;

  /// Wall taps so far on wall 1 and wall 2, and which wall is being tapped.
  final List<WallTap> tapsA;
  final List<WallTap> tapsB;
  final int wallIndex;

  /// A depth measurement is in flight (taps are ignored meanwhile).
  final bool measuring;

  /// How corner A was snapped. A rough one (`floorTap`, `depthTaps`) makes
  /// the corner-B card ask for a long baseline first.
  final String? cornerAMethod;

  /// Corner A's heading was already set from a long baseline.
  final bool baselineDone;

  /// Why the last "Use this corner" on corner A didn't place the model.
  final ArCornerProblem? cornerProblem;

  /// `inside | outside`: the shape the user snapped, for [cornerProblem]'s
  /// wording and the plan's filter.
  final String? problemShape;

  /// Bumped when the same problem happens again: the card buzzes instead
  /// of repeating a toast.
  final int problemSeq;

  /// A one-off note for the coach strip ("Using #1 · Bedroom 1 · NW
  /// corner…"): setup speaks from one status area instead of stacking
  /// toasts over the camera (owner, 2026-10-06).
  final String? noticeKey;
  final List<Object> noticeArgs;
  final int noticeSeq;

  /// The number a corner's pin carries on the plan (its place in [ranked]),
  /// or null when it isn't offered. The chip and the start card say "#n"
  /// with this; "Corner 1 of 2" is always the setup step, never a pin.
  int? pinOf(CornerCandidate? c) {
    if (c == null) return null;
    final i = ranked.indexWhere((x) => x.id == c.id);
    return i < 0 ? null : i + 1;
  }

  /// The wall-taps offer: walls not tracked, or the snap fell back to a
  /// floor tap (one borrowed wall for heading).
  bool get offerWallTaps => wallsMissing || snapped?.method == 'floorTap';

  /// Corner A's heading is rough and no baseline fixed it yet.
  bool get wantsBaseline =>
      !baselineDone && (cornerAMethod == 'floorTap' || cornerAMethod == WallFitter.method);

  List<WallTap> get currentTaps => wallIndex == 0 ? tapsA : tapsB;

  ArSetupState copyWith({
    ArSetupStep? step,
    ArPlaceMethod? method,
    ArPlaceMethod? recommended,
    bool? rememberChoice,
    List<CornerCandidate>? ranked,
    CornerCandidate? chosenA,
    String? cornerAId,
    DetectedCorner? snapped,
    bool clearSnapped = false,
    int? snapSeq,
    CornerCandidate? suggestedB,
    CornerCandidate? matchedB,
    bool clearMatchedB = false,
    List<CornerMatch>? ambiguousB,
    bool? noMatchB,
    bool? tooCloseB,
    ArMarkerSighting? sighting,
    bool clearSighting = false,
    String? lockingCode,
    bool clearLocking = false,
    double? lockProgress,
    int? lockSeq,
    ArMarkerInfo? nextBoard,
    bool clearNextBoard = false,
    ArPinSpec? ghost,
    String? pendingCode,
    Vec3? pendingPosTile,
    Vec3? pendingNormalTile,
    double? pendingHeightM,
    double? pendingScalePct,
    String? pendingName,
    bool? pendingIsSpare,
    bool clearPending = false,
    String? otherFloorName,
    String? otherFloorCode,
    bool clearOtherFloor = false,
    bool? saving,
    String? savedLabel,
    String? saveError,
    bool clearSaveError = false,
    bool? saveQueued,
    bool? returnToWork,
    bool? wallsMissing,
    ArSetupStep? wallsFor,
    List<WallTap>? tapsA,
    List<WallTap>? tapsB,
    int? wallIndex,
    bool? measuring,
    String? cornerAMethod,
    bool? baselineDone,
    ArCornerProblem? cornerProblem,
    String? problemShape,
    bool clearProblem = false,
    int? problemSeq,
    String? noticeKey,
    List<Object>? noticeArgs,
    int? noticeSeq,
  }) => ArSetupState(
    step: step ?? this.step,
    method: method ?? this.method,
    recommended: recommended ?? this.recommended,
    rememberChoice: rememberChoice ?? this.rememberChoice,
    ranked: ranked ?? this.ranked,
    chosenA: chosenA ?? this.chosenA,
    cornerAId: cornerAId ?? this.cornerAId,
    snapped: clearSnapped ? null : (snapped ?? this.snapped),
    snapSeq: snapSeq ?? this.snapSeq,
    suggestedB: suggestedB ?? this.suggestedB,
    matchedB: clearMatchedB ? null : (matchedB ?? this.matchedB),
    ambiguousB: ambiguousB ?? this.ambiguousB,
    noMatchB: noMatchB ?? this.noMatchB,
    tooCloseB: tooCloseB ?? this.tooCloseB,
    sighting: clearSighting ? null : (sighting ?? this.sighting),
    lockingCode: clearLocking ? null : (lockingCode ?? this.lockingCode),
    lockProgress: lockProgress ?? this.lockProgress,
    lockSeq: lockSeq ?? this.lockSeq,
    nextBoard: clearNextBoard ? null : (nextBoard ?? this.nextBoard),
    ghost: ghost ?? this.ghost,
    pendingCode: clearPending ? null : (pendingCode ?? this.pendingCode),
    pendingPosTile: clearPending ? null : (pendingPosTile ?? this.pendingPosTile),
    pendingNormalTile: clearPending ? null : (pendingNormalTile ?? this.pendingNormalTile),
    pendingHeightM: clearPending ? null : (pendingHeightM ?? this.pendingHeightM),
    pendingScalePct: clearPending ? null : (pendingScalePct ?? this.pendingScalePct),
    pendingName: clearPending ? null : (pendingName ?? this.pendingName),
    pendingIsSpare: pendingIsSpare ?? this.pendingIsSpare,
    otherFloorName: clearOtherFloor ? null : (otherFloorName ?? this.otherFloorName),
    otherFloorCode: clearOtherFloor ? null : (otherFloorCode ?? this.otherFloorCode),
    saving: saving ?? this.saving,
    savedLabel: savedLabel ?? this.savedLabel,
    saveError: clearSaveError ? null : (saveError ?? this.saveError),
    saveQueued: saveQueued ?? this.saveQueued,
    returnToWork: returnToWork ?? this.returnToWork,
    wallsMissing: wallsMissing ?? this.wallsMissing,
    wallsFor: wallsFor ?? this.wallsFor,
    tapsA: tapsA ?? this.tapsA,
    tapsB: tapsB ?? this.tapsB,
    wallIndex: wallIndex ?? this.wallIndex,
    measuring: measuring ?? this.measuring,
    cornerAMethod: cornerAMethod ?? this.cornerAMethod,
    baselineDone: baselineDone ?? this.baselineDone,
    cornerProblem: clearProblem ? null : (cornerProblem ?? this.cornerProblem),
    problemShape: clearProblem ? null : (problemShape ?? this.problemShape),
    problemSeq: problemSeq ?? this.problemSeq,
    noticeKey: noticeKey ?? this.noticeKey,
    noticeArgs: noticeArgs ?? this.noticeArgs,
    noticeSeq: noticeSeq ?? this.noticeSeq,
  );
}

class ArSetupController extends AutoDisposeNotifier<ArSetupState> {
  CornerMatcher _matcher = const CornerMatcher();
  Timer? _snapPoll;
  Timer? _lockTimer;

  /// The floor pack setup was initialised for. A new instance means the
  /// session (re)started — a Demo toggle, a retry — so setup starts over.
  ArFloorContext? _initialisedFor;
  var _lastCornerSeq = -1;
  var _lastMarkerSeq = -1;
  var _lastCoachSeq = 0;
  var _disposed = false;

  static const _fitter = WallFitter();
  static const _baseline = BaselineHeading();

  /// A wall tap needs at least this depth confidence ([ArDepthPoint.confidence]).
  static const minTapConfidence = 0.3;

  ArSessionController get _session => ref.read(arSessionProvider.notifier);
  ArSessionState get _s => ref.read(arSessionProvider);

  @override
  ArSetupState build() {
    ref.onDispose(() {
      _disposed = true;
      _snapPoll?.cancel();
      _lockTimer?.cancel();
    });
    ref.listen<ArSessionState>(arSessionProvider, _onSession);
    // Created after the session was already running (a rebuild): catch up.
    final now = ref.read(arSessionProvider);
    _lastCoachSeq = now.coachSeq;
    if (now.phase == ArSessionPhase.running && now.floor != null) {
      Future.microtask(() => _onSession(null, ref.read(arSessionProvider)));
    }
    return const ArSetupState();
  }

  void _set(ArSetupState next) {
    if (_disposed) return;
    state = next;
  }

  // ------------------------------------------------------------ start-up

  void _onSession(ArSessionState? prev, ArSessionState next) {
    final floor = next.floor;
    if (floor != null && next.phase == ArSessionPhase.running && !identical(_initialisedFor, floor)) {
      _initialisedFor = floor;
      _stopSnapPolling();
      _lockTimer?.cancel();
      _lockTimer = null;
      _set(const ArSetupState());
      unawaited(_init(next));
    }
    final corner = next.lastCorner;
    if (corner != null && corner.seq != _lastCornerSeq) {
      _lastCornerSeq = corner.seq;
      _onCorner(corner.corner);
    }
    if (next.coachSeq != _lastCoachSeq) {
      _lastCoachSeq = next.coachSeq;
      final aiming = state.step == ArSetupStep.cornerA || state.step == ArSetupStep.cornerB;
      if (next.coachCode == 'corner-no-walls' && aiming && !state.wallsMissing) {
        _set(state.copyWith(wallsMissing: true));
      }
    }
    final marker = next.lastMarker;
    if (marker != null && marker.seq != _lastMarkerSeq) {
      _lastMarkerSeq = marker.seq;
      unawaited(_onMarker(marker));
    }
    if (prev?.plan == null && next.plan != null && floor != null) {
      _set(state.copyWith(ranked: _rankCorners(floor, next)));
    }
  }

  Future<void> _init(ArSessionState s) async {
    final floor = s.floor!;
    final args = s.args!;
    _matcher = CornerMatcher(floorFinishOffsetM: floor.floorFinishOffsetM);
    final recommended = recommendMethod(floor, args);
    final ranked = _rankCorners(floor, s);
    _set(state.copyWith(recommended: recommended, ranked: ranked, chosenA: ranked.isEmpty ? null : ranked.first));

    // The board that opened the session decides (§7 rule 1).
    if (args.focusCode != null) {
      _enterMethod(ArPlaceMethod.board);
      return;
    }
    var method = args.method;
    method ??= await ref.read(arPrefsProvider.notifier).rememberedMethod(floor.floorId);
    if (_disposed) return;
    if (method != null && method != ArPlaceMethod.resume && method != ArPlaceMethod.gnss) {
      _enterMethod(method);
    } else {
      _set(state.copyWith(step: ArSetupStep.choose));
    }
  }

  /// "Scan a board · Best here" when this room (or, without a room, this
  /// floor) has boards up; otherwise corners (AR-54).
  static ArPlaceMethod recommendMethod(ArFloorContext floor, ArSessionArgs args) {
    if (args.focusCode != null) return ArPlaceMethod.board;
    final active = floor.activeMarkers;
    if (active.isEmpty) return ArPlaceMethod.corners;
    final room = args.spaceName?.trim().toLowerCase();
    if (room == null || room.isEmpty) return ArPlaceMethod.board;
    final inRoom = active.where((m) => (m.locationText ?? '').toLowerCase().contains(room));
    return inRoom.isNotEmpty ? ArPlaceMethod.board : ArPlaceMethod.corners;
  }

  List<CornerCandidate> _rankCorners(ArFloorContext floor, ArSessionState s) {
    var pool = floor.corners;
    if (state.method == ArPlaceMethod.grid) {
      final columns = pool.where((c) => c.kind == 'column').toList();
      if (columns.isNotEmpty) pool = columns;
    }
    var space = s.args?.spaceName;
    // From an asset or work order the target's room narrows the choice.
    final target = s.target;
    if ((space == null || space.isEmpty) && target != null && s.plan != null) {
      space = s.plan!.spaceAt(target.centre.x, target.centre.z)?.name;
    }
    final ranked = _matcher.rankForRoom(pool, spaceName: space);
    if (state.method == ArPlaceMethod.grid) return ranked;
    // Indoors the corners you can walk up to are the room's inside corners.
    // A column's outside corner ranked first (structural) became the default
    // target on the first device run, and a room-corner snap was matched to
    // a column corner outside the building (4 m off).
    return [
      ...ranked.where((c) => c.kind == 'inside'),
      ...ranked.where((c) => c.kind != 'inside'),
    ];
  }

  // ------------------------------------------------------------- choose

  void toggleRemember(bool on) => _set(state.copyWith(rememberChoice: on));

  Future<void> chooseMethod(ArPlaceMethod m) async {
    final floor = _s.floor;
    if (floor != null) {
      await ref.read(arPrefsProvider.notifier).rememberMethod(floor.floorId, state.rememberChoice ? m : null);
    }
    _enterMethod(m);
  }

  void _enterMethod(ArPlaceMethod m) {
    final s = _s;
    _set(state.copyWith(method: m));
    if (s.floor != null) _set(state.copyWith(ranked: _rankCorners(s.floor!, s)));
    switch (m) {
      case ArPlaceMethod.board:
        _set(state.copyWith(step: ArSetupStep.boardScan, clearSighting: true, clearLocking: true, lockProgress: 0));
      case ArPlaceMethod.corners:
      case ArPlaceMethod.grid:
        final ranked = state.ranked;
        // Keep the user's pick if it's still a choice (grid mode narrows the
        // list to columns), else the best-ranked corner.
        final keep = state.chosenA != null && ranked.any((c) => c.id == state.chosenA!.id);
        _set(state.copyWith(step: ArSetupStep.start, chosenA: keep ? state.chosenA : (ranked.isEmpty ? null : ranked.first)));
        if (ranked.isEmpty) {
          _session.toast('ar.toast.no_corners', tone: ArToastTone.warning);
        }
      case ArPlaceMethod.resume:
      case ArPlaceMethod.gnss:
        _set(state.copyWith(step: ArSetupStep.choose));
    }
  }

  /// Back to the chooser ("Other method").
  void otherMethod() {
    _stopSnapPolling();
    _set(state.copyWith(step: ArSetupStep.choose, clearSnapped: true, clearProblem: true));
  }

  // ------------------------------------------------------------ corners

  /// A corner tapped on the plan. Clears any "wrong shape" explanation:
  /// the user has answered it.
  void chooseCornerA(CornerCandidate c) => _set(state.copyWith(chosenA: c, clearProblem: true));

  void startCornerA() {
    if (state.chosenA == null) return;
    _set(state.copyWith(step: ArSetupStep.cornerA, clearSnapped: true, clearProblem: true));
    _startSnapPolling();
  }

  /// Polls the engine for a corner under the pin in the middle of the view,
  /// alongside the engine's own `corner` events (§2.3: aim roughly, the pin
  /// finds the exact edge).
  void _startSnapPolling() {
    _snapPoll?.cancel();
    if (_s.demo) return;
    _snapPoll = Timer.periodic(const Duration(milliseconds: 600), (_) async {
      if (_disposed) return;
      if (state.step != ArSetupStep.cornerA && state.step != ArSetupStep.cornerB) {
        _stopSnapPolling();
        return;
      }
      final view = _session.viewSize;
      final d = await _session.detectCornerAt(view.width / 2, view.height / 2);
      if (d != null && !_disposed) _onCorner(d);
    });
  }

  void _stopSnapPolling() {
    _snapPoll?.cancel();
    _snapPoll = null;
  }

  void _onCorner(DetectedCorner d) {
    // The poll keeps snapping while the user decides; a floor-tap fallback
    // must not replace the corner just fitted from wall taps (a better one,
    // from tracked planes or LiDAR, still may).
    final keep = state.snapped?.method == WallFitter.method && d.method == 'floorTap';
    switch (state.step) {
      case ArSetupStep.cornerA:
        if (keep) return;
        // A snap of another shape means the user moved to another corner:
        // the old explanation no longer describes where they stand.
        final stale = state.problemShape != null && state.problemShape != CornerMatcher.shapeOf(d.kind);
        _set(state.copyWith(snapped: d, snapSeq: state.snapSeq + 1, clearProblem: stale));
      case ArSetupStep.cornerB:
        if (keep) return;
        _matchB(d);
      default:
        // A snap outside setup (auto re-snap) refines the fit when it matches.
        if (_s.stage == ArSessionStage.work && _s.fit != null && _s.isPlaced) {
          final near = _matcher.candidatesNear(d, _s.fit!, _s.floor?.corners ?? const []);
          if (near.length == 1) {
            final before = _s.fit!;
            final fit = _session.addObservation(
              _matcher.observe(d, near.first.candidate, cameraAr: _s.cameraAr, yawPrior: before.yawRad),
            );
            final moved = before.t.distanceTo(fit.t);
            if (moved >= 0.01) {
              _session.toast('ar.toast.corrected', args: [(moved * 100).round()], tone: ArToastTone.success);
            }
          }
        }
    }
  }

  void _matchB(DetectedCorner d) {
    final fit = _s.fit;
    final floor = _s.floor;
    if (fit == null || floor == null) return;
    final near = _matcher.candidatesNear(
      d,
      fit,
      floor.corners,
      excludeIds: {if (state.cornerAId != null) state.cornerAId!},
    );
    if (near.isEmpty) {
      _set(state.copyWith(snapped: d, snapSeq: state.snapSeq + 1, clearMatchedB: true, ambiguousB: const [], noMatchB: true));
    } else if (near.length >= 2 && (near[1].distanceM - near[0].distanceM) < 0.25) {
      _set(state.copyWith(snapped: d, snapSeq: state.snapSeq + 1, clearMatchedB: true, ambiguousB: near.take(2).toList(), noMatchB: false));
    } else {
      final a = _firstWhere(floor.corners, (c) => c.id == state.cornerAId);
      final tooClose = a != null && a.posTile.distanceXzTo(near.first.candidate.posTile) < CornerMatcher.lockSeparationM;
      _set(state.copyWith(
        snapped: d,
        snapSeq: state.snapSeq + 1,
        matchedB: near.first.candidate,
        ambiguousB: const [],
        noMatchB: false,
        tooCloseB: tooClose,
      ));
    }
  }

  /// "Use this corner" on corner A: one corner is already a full 4-DoF
  /// placement (position and heading), so the badge goes amber.
  ///
  /// The snap must have the picked corner's shape (inside vs column /
  /// outside, angle within the method's tolerance). If it doesn't, the best
  /// corner of the snapped shape is looked for on the **whole floor**, near
  /// where the user is (the last camera position, else the picked corner):
  /// close by, it is used and named; far away or nowhere, the card explains
  /// why and what to do (first iPhone run 2026-10-06: an inside-corner snap
  /// on a model whose short list held only column corners got the vague
  /// `corner_rejected` toast, again on every tap, and no way forward).
  void useCornerA() {
    final d = state.snapped;
    var a = state.chosenA;
    final floor = _s.floor;
    if (d == null || a == null || floor == null) return;
    final fb = _matcher.fallbackFor(d, a, floor.corners, near: _s.cameraTile);
    switch (fb.kind) {
      case ShapeFallbackKind.matches:
        break;
      case ShapeFallbackKind.switched:
        a = fb.candidate!;
        final pick = a;
        // From outside the room's short list: give it a pin so the plan,
        // the chip and the toast all name it the same way.
        final ranked = state.ranked.any((c) => c.id == pick.id) ? state.ranked : [...state.ranked, pick];
        _set(state.copyWith(chosenA: pick, ranked: ranked, clearProblem: true));
        _set(state.copyWith(
          noticeKey: 'ar.toast.corner_switched',
          noticeArgs: [state.pinOf(pick) ?? 1, pick.label],
          noticeSeq: state.noticeSeq + 1,
        ));
      case ShapeFallbackKind.nearbyOtherShape:
        // Offer the far same-shape corners on the plan too.
        final extra = [for (final c in fb.sameShape) if (!state.ranked.any((r) => r.id == c.id)) c];
        if (extra.isNotEmpty) _set(state.copyWith(ranked: [...state.ranked, ...extra]));
        _explain(ArCornerProblem.otherShapeNearby, fb.snappedShape);
        return;
      case ShapeFallbackKind.noneOfShape:
        _explain(ArCornerProblem.noneOfShape, fb.snappedShape);
        return;
    }
    final obsA = _matcher.firstCorner(d, a, cameraAr: _s.cameraAr);
    final fit = _session.addObservation(obsA);
    if (fit.quality == AlignmentQuality.siteMismatch) {
      // Only with observations kept from before (re-align from work): the
      // new corner disagrees with them.
      _stopSnapPolling();
      _set(state.copyWith(step: ArSetupStep.mismatch, clearProblem: true));
      return;
    }
    if (!fit.isPlaced) {
      _explain(ArCornerProblem.notPlaced, CornerMatcher.shapeOf(d.kind));
      return;
    }
    unawaited(_session.anchorObservation(obsA));
    final suggestions = _matcher.suggestSecond(a, floor.corners);
    _set(state.copyWith(
      step: ArSetupStep.cornerB,
      cornerAId: a.id,
      cornerAMethod: d.method,
      baselineDone: false,
      wallsMissing: false,
      clearSnapped: true,
      clearMatchedB: true,
      ambiguousB: const [],
      noMatchB: false,
      tooCloseB: false,
      clearProblem: true,
      suggestedB: suggestions.isEmpty ? null : suggestions.first,
    ));
    _startSnapPolling();
  }

  /// Puts [problem] on the coach strip and the card — the reason and the
  /// next step, never a toast (the strip is setup's one status area). The
  /// same problem again bumps [ArSetupState.problemSeq] so the card buzzes
  /// instead of repeating itself.
  void _explain(ArCornerProblem problem, String shape) {
    _set(state.copyWith(cornerProblem: problem, problemShape: shape, problemSeq: state.problemSeq + 1));
  }

  /// "Try the demo room": Demo mode's sample building, from the card that
  /// says this model may not be this room.
  Future<void> tryDemoRoom() async {
    _stopSnapPolling();
    await ref.read(arPrefsProvider.notifier).setDemo(true);
    if (_disposed) return;
    await _session.restart();
  }

  /// "Use this corner" on corner B ([pick] answers the two-button question).
  void useCornerB([CornerCandidate? pick]) {
    final d = state.snapped;
    final c = pick ?? state.matchedB;
    final before = _s.fit;
    if (d == null || c == null) return;
    final obsB = _matcher.observe(d, c, cameraAr: _s.cameraAr, yawPrior: before?.yawRad);
    final fit = _session.addObservation(obsB);
    unawaited(_session.anchorObservation(obsB));
    _stopSnapPolling();
    _afterFit(fit, via: 'corner');
  }

  // ------------------------------------------------------------ wall taps

  /// "Tap the walls": plain walls gave no corner (or only a floor tap).
  void startWallTaps() {
    final back = state.step == ArSetupStep.cornerB ? ArSetupStep.cornerB : ArSetupStep.cornerA;
    _stopSnapPolling();
    _set(state.copyWith(
      step: ArSetupStep.wallTaps,
      wallsFor: back,
      tapsA: const [],
      tapsB: const [],
      wallIndex: 0,
      measuring: false,
    ));
  }

  /// A tap on the camera view at ([x], [y]) view pixels while tapping walls.
  Future<void> addWallTap(double x, double y) async {
    if (state.step != ArSetupStep.wallTaps || state.measuring) return;
    _set(state.copyWith(measuring: true));
    final p = await _session.depthPointAt(x, y);
    if (_disposed) return;
    _set(state.copyWith(measuring: false));
    if (state.step != ArSetupStep.wallTaps) return;
    final reject = wallTapRejection(p, _session.floorAr);
    if (reject != null) {
      _session.toast(reject, tone: ArToastTone.warning);
      return;
    }
    final tap = WallTap(p!.posAr, p.normalAr);
    if (state.wallIndex == 0) {
      final taps = [...state.tapsA, tap];
      _set(state.copyWith(tapsA: taps));
      if (taps.length >= WallFitter.maxTaps) nextWall();
    } else {
      final taps = [...state.tapsB, tap];
      _set(state.copyWith(tapsB: taps));
      if (taps.length >= WallFitter.maxTaps) fitWallCorner();
    }
  }

  /// Why a measured point can't be a wall tap (an `ar.walls.*` key), or null.
  static String? wallTapRejection(ArDepthPoint? p, double? floorY) {
    if (p == null) return 'ar.walls.no_depth';
    if (p.confidence < minTapConfidence) return 'ar.walls.low_confidence';
    if (WallFitter.looksLikeFloor(p.normalAr) || (floorY != null && p.posAr.y - floorY < 0.03)) {
      return 'ar.walls.floor';
    }
    return null;
  }

  /// Wall 1 done ("Next wall"): checked on its own first, so a bad wall is
  /// redone before the second one is tapped.
  void nextWall() {
    if (state.tapsA.length < WallFitter.minTaps) return;
    final r = _fitter.fit(state.tapsA, cameraAr: _s.cameraAr);
    if (!r.ok) {
      _session.toast(_wallFailureKey(r.failure!), tone: ArToastTone.warning);
      _set(state.copyWith(tapsA: const []));
      return;
    }
    _set(state.copyWith(wallIndex: 1));
  }

  void undoWallTap() {
    if (state.wallIndex == 1 && state.tapsB.isEmpty) {
      _set(state.copyWith(wallIndex: 0));
      return;
    }
    final taps = List<WallTap>.of(state.currentTaps);
    if (taps.isEmpty) return;
    taps.removeLast();
    _set(state.wallIndex == 0 ? state.copyWith(tapsA: taps) : state.copyWith(tapsB: taps));
  }

  /// Both walls tapped: fit them, intersect on the tracked floor, and hand
  /// the corner to the step that asked, exactly like a native snap.
  void fitWallCorner() {
    final cam = _s.cameraAr;
    // The tracked floor; without one, the floor-tap snap that led here.
    final floorY = _session.floorAr ?? state.snapped?.posAr.y;
    if (floorY == null) {
      _session.toast('ar.coach.floor', tone: ArToastTone.warning);
      return;
    }
    if (cam == null) {
      _session.toast('ar.coach.tracking', tone: ArToastTone.warning);
      return;
    }
    final r = _fitter.corner(state.tapsA, state.tapsB, floorY: floorY, cameraAr: cam);
    if (!r.ok) {
      _session.toast(_wallFailureKey(r.failure!), tone: ArToastTone.warning);
      if (r.failure == WallFitFailure.parallel || r.failure == WallFitFailure.tooFar) {
        // Most likely both walls were the same wall, or one tap hit a door:
        // redo wall 2, keep wall 1.
        _set(state.copyWith(tapsB: const []));
      }
      return;
    }
    final corner = r.value!;
    _set(state.copyWith(
      step: state.wallsFor ?? ArSetupStep.cornerA,
      wallsMissing: false,
      tapsA: const [],
      tapsB: const [],
      wallIndex: 0,
      clearSnapped: true,
    ));
    _onCorner(corner.toDetected());
    _session.toast('ar.walls.fitted', args: [math.max(1, (corner.rmsM * 1000).round())], tone: ArToastTone.success);
    _startSnapPolling();
  }

  /// Back to aiming without a fitted corner.
  void cancelWallTaps() {
    _set(state.copyWith(step: state.wallsFor ?? ArSetupStep.cornerA, tapsA: const [], tapsB: const [], wallIndex: 0));
    _startSnapPolling();
  }

  static String _wallFailureKey(WallFitFailure f) => switch (f) {
        WallFitFailure.tooFewTaps => 'ar.walls.too_few',
        WallFitFailure.noDirection => 'ar.walls.spread_out',
        WallFitFailure.parallel => 'ar.walls.parallel',
        WallFitFailure.tooFar => 'ar.walls.too_far',
      };

  // ------------------------------------------------------------- baseline

  /// "Tap a wall base instead" (after a rough corner A).
  void startBaseline() {
    _stopSnapPolling();
    _set(state.copyWith(step: ArSetupStep.baseline, measuring: false));
  }

  /// A tap where a wall of corner A meets the floor, 2–5 m along it.
  Future<void> addBaselineTap(double x, double y) async {
    if (state.step != ArSetupStep.baseline || state.measuring) return;
    _set(state.copyWith(measuring: true));
    final p = await _session.depthPointAt(x, y);
    if (_disposed) return;
    _set(state.copyWith(measuring: false));
    if (state.step != ArSetupStep.baseline) return;
    if (p == null || p.confidence < minTapConfidence) {
      _session.toast('ar.walls.no_depth', tone: ArToastTone.warning);
      return;
    }
    CornerObs? a;
    for (final o in _s.observations) {
      if (o is CornerObs && o.id == state.cornerAId) a = o;
    }
    if (a == null) {
      cancelBaseline();
      return;
    }
    final r = _baseline.refine(a, p.posAr);
    if (!r.ok) {
      _session.toast(
        r.rejected == BaselineRejection.tooShort ? 'ar.baseline.too_short' : 'ar.baseline.not_along',
        args: [r.lengthM.toStringAsFixed(1)],
        tone: ArToastTone.warning,
      );
      return;
    }
    _session.addObservation(r.corner!);
    _set(state.copyWith(step: ArSetupStep.cornerB, baselineDone: true, clearSnapped: true, clearMatchedB: true));
    _session.toast(
      'ar.baseline.done',
      args: [r.correctionDeg.abs().toStringAsFixed(1), r.lengthM.toStringAsFixed(1)],
      tone: ArToastTone.success,
    );
    _startSnapPolling();
  }

  void cancelBaseline() {
    _set(state.copyWith(step: ArSetupStep.cornerB, measuring: false));
    _startSnapPolling();
  }

  /// Keep corner A only and carry on amber ("Carry on").
  void carryOn() {
    _stopSnapPolling();
    _finish();
  }

  // --------------------------------------------------------------- boards

  Future<void> _onMarker(ArMarkerSighting m) async {
    final s = _s;
    final floor = s.floor;
    if (floor == null) return;
    if (m.code == null) {
      // While working, a non-board QR is an asset tag (Verify handles it).
      if (s.stage != ArSessionStage.work) _session.toast('ar.toast.not_a_board', tone: ArToastTone.warning);
      return;
    }
    final known = floor.markerByCode(m.code!);
    final awaitingInstall = known != null && (known.status == 'planned' || known.status == 'printed');
    if (s.args?.installCode != null && (awaitingInstall || m.code == s.args!.installCode)) {
      // The installer's self-check owns these sightings.
      return;
    }
    if (awaitingInstall) {
      _session.toast('ar.toast.board_not_active', args: [known.label], tone: ArToastTone.warning);
      return;
    }
    if (known != null && known.usableForAlignment) {
      if (state.step == ArSetupStep.boardLock && state.lockingCode == known.code && _lockTimer != null) return;
      if (s.stage == ArSessionStage.work) {
        _refineWithBoard(known, m);
        return;
      }
      _set(state.copyWith(step: ArSetupStep.boardLock, lockingCode: known.code, sighting: m, lockProgress: 0));
      if (m.acceptable) _runLockRing(known, m);
      return;
    }
    if (known != null && known.isRetired) {
      _session.toast('ar.toast.board_retired', args: [known.label], tone: ArToastTone.warning);
      return;
    }
    // A spare, or a board that isn't on this floor's pack: ask the server
    // (or the pack's spare list) what it is.
    final isSpareHere = known?.isSpare ?? false;
    ArResolveResult? resolved;
    if (!isSpareHere) {
      try {
        resolved = await ref.read(arSessionProvider.notifier).gateway?.resolveMarker(m.code!);
      } catch (_) {
        resolved = null;
      }
    }
    if (_disposed) return;
    if (resolved is ArResolved && resolved.floorId != floor.floorId) {
      // The prompt lives in the setup layer; while working, lift it up and
      // come back to work if the user stays.
      if (s.stage == ArSessionStage.work) {
        _session.backToSetup();
        _set(state.copyWith(returnToWork: true));
      }
      _set(state.copyWith(otherFloorCode: resolved.marker.code, otherFloorName: resolved.floorName));
      return;
    }
    if (resolved is ArResolved && resolved.marker.usableForAlignment) {
      // Known after all (a board added since the pack was downloaded).
      if (s.stage == ArSessionStage.work) {
        _refineWithBoard(resolved.marker, m);
      } else {
        _set(state.copyWith(step: ArSetupStep.boardLock, lockingCode: resolved.marker.code, sighting: m, lockProgress: 0));
        if (m.acceptable) _runLockRing(resolved.marker, m);
      }
      return;
    }
    if (resolved is ArResolveFailed && resolved.code == 'RETIRED') {
      _session.toast('ar.toast.board_retired', args: [resolved.nearestLabel ?? m.code!], tone: ArToastTone.warning);
      return;
    }
    if (resolved is ArResolveFailed && resolved.code == 'NO_ACCESS') {
      _session.toast('ar.resolve.no_access', tone: ArToastTone.error);
      return;
    }
    _offerRegister(m, isSpare: isSpareHere || (resolved is ArResolveFailed && resolved.code == 'SPARE_UNBOUND'));
  }

  /// "Board hard to see?" coaching: a sighting that failed acceptance just
  /// updates the chips; the engine keeps looking.
  void _runLockRing(ArMarkerInfo board, ArMarkerSighting m) {
    _lockTimer?.cancel();
    var progress = 0.0;
    _lockTimer = Timer.periodic(const Duration(milliseconds: 40), (t) {
      if (_disposed) {
        t.cancel();
        return;
      }
      progress += 40 / 750;
      if (progress < 1) {
        _set(state.copyWith(lockProgress: progress));
        return;
      }
      t.cancel();
      _lockTimer = null;
      _set(state.copyWith(lockProgress: 1, lockSeq: state.lockSeq + 1));
      final fit = _session.addObservation(_markerObs(board, m), anchorId: m.anchorId);
      _afterFit(fit, via: 'board');
    });
  }

  MarkerObs _markerObs(ArMarkerInfo board, ArMarkerSighting m) => MarkerObs(
    id: board.code,
    aAr: m.centreAr,
    bTile: board.posTile,
    // Contract C2: a PnP-only sighting doubles the board's sigma. The
    // manifest always carries the class sigma (`sigmaM`), so the doubling
    // has to apply on top of it, not only when the server sent none.
    sigmaM: m.method == 'tag'
        ? math.max(ArSigma.surveyed, board.classSigmaM * 0.7)
        : board.classSigmaM * (m.method == 'pnp' ? 2 : 1),
    normalAr: m.normalAr,
    normalTile: board.normalTile,
    method: m.method,
  );

  /// A known board seen while working: it just refines the fit (§2.6).
  void _refineWithBoard(ArMarkerInfo board, ArMarkerSighting m) {
    if (!m.acceptable) return;
    final before = _s.fit;
    final fit = _session.addObservation(_markerObs(board, m), anchorId: m.anchorId);
    final moved = before == null ? 0.0 : before.t.distanceTo(fit.t);
    _session.toast(
      'ar.toast.board_checked',
      args: [board.label, math.max(1, (fit.maxResidualM * 100).ceil())],
      tone: fit.quality == AlignmentQuality.siteMismatch ? ArToastTone.warning : ArToastTone.success,
    );
    if (moved >= 0.02 && fit.quality != AlignmentQuality.siteMismatch) {
      _session.toast('ar.toast.corrected', args: [(moved * 100).round()], tone: ArToastTone.success);
    }
  }

  /// Retry after a coaching failure (the next sighting restarts the ring).
  void retryLock() => _set(state.copyWith(step: ArSetupStep.boardScan, clearSighting: true, clearLocking: true, lockProgress: 0));

  void _afterFit(AlignmentFit fit, {required String via}) {
    final s = _s;
    // Re-snap / re-scan from the workspace: any usable fit goes straight back
    // to work (the badge and a "Corrected" toast say what changed).
    if (state.returnToWork &&
        fit.quality != AlignmentQuality.siteMismatch &&
        fit.quality != AlignmentQuality.none) {
      _finish();
      return;
    }
    switch (fit.quality) {
      case AlignmentQuality.locked:
        // "No board nearby" (§2.5) means none in this part of the room: a
        // board 4 m away is one the user can already see from here.
        final nearBoard = _boardWithin(4);
        if (nearBoard || via == 'board') {
          _set(state.copyWith(step: ArSetupStep.locked, clearNextBoard: true));
          if (via == 'board') _finish();
        } else {
          _set(state.copyWith(step: ArSetupStep.locked, ghost: _ghostSpot()));
          final g = state.ghost;
          if (g != null) unawaited(_session.setPins([g]));
        }
      case AlignmentQuality.siteMismatch:
        _set(state.copyWith(step: ArSetupStep.mismatch));
      case AlignmentQuality.placed:
      case AlignmentQuality.manual:
      case AlignmentQuality.drifting:
        if (via == 'board') {
          _set(state.copyWith(step: ArSetupStep.aligned, nextBoard: _nextBoard(s)));
        } else {
          // Two corners too close together: still amber, ask for a farther one.
          _set(state.copyWith(step: ArSetupStep.cornerB, clearSnapped: true, clearMatchedB: true, tooCloseB: true));
          _startSnapPolling();
        }
      case AlignmentQuality.none:
        break;
    }
  }

  bool _boardWithin(double metres) {
    final s = _s;
    final floor = s.floor;
    if (floor == null) return false;
    final here = s.cameraTile ?? (s.observations.isEmpty ? null : s.observations.last.bTile);
    if (here == null) return false;
    return floor.activeMarkers.any((m) => m.posTile.distanceXzTo(here) <= metres);
  }

  /// The best second board: not yet observed, 3 m or more from what is,
  /// nearest to where the user is. M4's radar points at it.
  ArMarkerInfo? _nextBoard(ArSessionState s) {
    final floor = s.floor;
    if (floor == null) return null;
    final seen = s.observations.map((o) => o.id).toSet();
    final here = s.cameraTile ?? (s.observations.isEmpty ? null : s.observations.last.bTile);
    if (here == null) return null;
    final candidates = floor.activeMarkers.where((m) => !seen.contains(m.code)).toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      double score(ArMarkerInfo m) {
        final d = m.posTile.distanceXzTo(here);
        return d < 3 ? d + 100 : d;
      }

      return score(a).compareTo(score(b));
    });
    return candidates.first;
  }

  /// Where a spare board would help most (§2.5): the same coverage model
  /// the web heatmap uses ([GhostSpotFinder]), scored around where the user
  /// stands. Falls back to 1.2 m along the wall of an inside corner we
  /// snapped when the finder has nothing (a floor with no corner walls).
  ArPinSpec? _ghostSpot() {
    final s = _s;
    final floor = s.floor;
    if (floor == null) return null;
    // The live gateway keeps the full plan it fetched: with it the finder
    // keeps suggestions clear of doors and equipment (P-008 item 5).
    final gw = ref.read(arSessionProvider.notifier).gateway;
    final spots = const GhostSpotFinder().suggest(
      plan: gw is LiveArGateway ? gw.cachedFloorPlan(floor.floorId) : null,
      corners: floor.corners,
      markers: [
        for (final m in floor.activeMarkers)
          ManifestMarker(
            code: m.code,
            label: m.label,
            status: m.status,
            accuracyClass: m.accuracyClass,
            mounting: m.mounting,
            posTile: m.posTile,
            normalTile: m.normalTile,
            sigmaM: m.classSigmaM,
          ),
      ],
      cameraTile: s.cameraTile,
      floorFinishOffsetM: floor.floorFinishOffsetM,
      limit: 1,
    );
    if (spots.isNotEmpty) {
      final g = spots.first;
      return ArPinSpec(id: 'ghost-board', posTile: g.posTile, kind: 'ghostBoard', normalTile: g.normalTile, label: g.cornerLabel);
    }
    final used = s.observations.map((o) => o.id).toSet();
    final corners = floor.corners.where((c) => used.contains(c.id)).toList()
      ..sort((a, b) => (a.kind == 'inside' ? 0 : 1).compareTo(b.kind == 'inside' ? 0 : 1));
    if (corners.isEmpty) return null;
    final c = corners.first;
    final along = c.kind == 'inside' ? c.faceB : -c.faceB;
    final reach = c.kind == 'inside' ? 1.2 : 0.3;
    final y = floor.floorDatumY + floor.floorFinishOffsetM + 1.5;
    return ArPinSpec(
      id: 'ghost-board',
      posTile: Vec3(
        c.posTile.x + along.x * reach + c.faceA.x * 0.01,
        y,
        c.posTile.z + along.y * reach + c.faceA.y * 0.01,
      ),
      kind: 'ghostBoard',
      normalTile: Vec3(c.faceA.x, 0, c.faceA.y),
    );
  }

  // ----------------------------------------------------- leave a board

  void leaveBoard() => _set(state.copyWith(step: ArSetupStep.leaveBoard));

  void _offerRegister(ArMarkerSighting m, {required bool isSpare}) {
    final s = _s;
    final fit = s.fit;
    final floor = s.floor!;
    if (fit == null || !(s.isLocked || fit.quality == AlignmentQuality.manual)) {
      // "Place the model first, then save this board" (AR-56).
      _session.toast('ar.register.place_first', tone: ArToastTone.warning);
      return;
    }
    if (s.stage == ArSessionStage.work) {
      // A spare scanned mid-job: the register card is a setup card, so lift
      // it over the workspace and return there when it's done.
      _session.backToSetup();
      _set(state.copyWith(returnToWork: true));
    }
    final pos = fit.arToTile(m.centreAr);
    final n = fit.dirArToTile(m.normalAr);
    final normal = Vec3(n.x, 0, n.z).normalized;
    final height = pos.y - (floor.floorDatumY + floor.floorFinishOffsetM);
    final space = s.plan?.spaceAt(pos.x, pos.z)?.name;
    _set(state.copyWith(
      step: ArSetupStep.register,
      pendingCode: m.code,
      pendingPosTile: pos,
      pendingNormalTile: normal,
      pendingHeightM: height,
      pendingScalePct: m.scalePct(115),
      pendingName: space,
      pendingIsSpare: isSpare,
      clearSaveError: true,
      saving: false,
      saveQueued: false,
    ));
  }

  /// Demo: the user "sticks" the spare on the ghost outline and scans it.
  void demoScanSpare() {
    final director = _session.director;
    final g = state.ghost;
    if (director == null || (g == null && _s.observations.isEmpty)) return;
    final spot = g?.posTile ?? _s.observations.last.bTile;
    final normal = g?.normalTile ?? const Vec3(1, 0, 0);
    _session.injectDemoMarker(director.sightingAt(DemoArGateway.demoSpareCode, spot, normal));
  }

  /// Demo: point at the focus board (or the nearest active one).
  void demoScanBoard({bool awkward = false}) {
    final director = _session.director;
    final floor = _s.floor;
    if (director == null || floor == null) return;
    final code = state.nextBoard?.code ?? _s.args?.focusCode;
    final board = (code == null ? null : floor.markerByCode(code)) ??
        (floor.activeMarkers.isEmpty ? null : floor.activeMarkers.first);
    if (board == null) return;
    _session.injectDemoMarker(awkward ? director.awkwardSightingFor(board) : director.markerFor(board));
  }

  /// Demo: snap the corner the screen asked for.
  void demoSnap() {
    final director = _session.director;
    final floor = _s.floor;
    if (director == null || floor == null) return;
    final CornerCandidate? target = switch (state.step) {
      ArSetupStep.cornerA => state.chosenA,
      ArSetupStep.cornerB => state.suggestedB ?? _firstWhere(floor.corners, (c) => c.id != state.cornerAId),
      _ => null,
    };
    if (target == null) return;
    _session.injectDemoCorner(director.cornerFor(target));
  }

  Future<void> saveBoard(String name) async {
    final s = _s;
    final floor = s.floor;
    final code = state.pendingCode;
    final pos = state.pendingPosTile;
    final normal = state.pendingNormalTile;
    final buildId = floor?.primaryBuildId;
    final gateway = _session.gateway;
    if (floor == null || code == null || pos == null || normal == null || buildId == null || gateway == null) return;
    _set(state.copyWith(saving: true, clearSaveError: true));
    // Derived: the fit's own uncertainty on top of the class sigma (§4.5).
    final sigma = math.max(0.03, (s.fit?.maxResidualM ?? 0.02) + 0.01);
    final result = await gateway.bindSpare(
      code: code,
      floorId: floor.floorId,
      buildId: buildId,
      posTile: pos,
      normalTile: normal,
      label: name.trim().isEmpty ? null : name.trim(),
      sigmaM: sigma,
    );
    if (_disposed) return;
    if (result.ok) {
      _set(state.copyWith(
        saving: false,
        savedLabel: result.marker?.label ?? (name.trim().isEmpty ? code : name.trim()),
        saveQueued: result.queued && !result.synced,
        clearPending: true,
      ));
      unawaited(_session.setPins(const []));
      _session.toast(
        result.synced ? 'ar.register.saved' : 'ar.offline_saved',
        args: result.synced ? [result.marker?.label ?? name] : const [],
        tone: ArToastTone.success,
      );
      _finish();
    } else {
      _set(state.copyWith(
        saving: false,
        saveError: result.errorCode == 'ALREADY_BOUND' ? 'ar.register.already_bound' : 'ar.register.failed',
      ));
    }
  }

  void notNow() {
    unawaited(_session.setPins(const []));
    _set(state.copyWith(clearPending: true));
    _finish();
  }

  void dismissOtherFloor() {
    _set(state.copyWith(clearOtherFloor: true));
    if (state.returnToWork) _finish();
  }

  // ---------------------------------------------------------------- nudge

  void startNudge() {
    _session.beginNudge();
    _set(state.copyWith(step: ArSetupStep.nudge));
  }

  /// 5 mm per tap (S5).
  void nudge(int taps) => _session.nudgeBy(taps * 0.005);

  void doneNudge() => _finish();

  void resetNudge() => _session.clearNudge();

  // ---------------------------------------------------------- from work

  /// Re-open setup from the workspace (menu → Re-align, rail → Re-snap).
  void reAlign({bool keepObservations = false}) {
    if (!keepObservations) _session.resetAlignment();
    _session.backToSetup();
    _set(state.copyWith(
      step: ArSetupStep.choose,
      returnToWork: keepObservations,
      clearSnapped: true,
      clearMatchedB: true,
      clearNextBoard: true,
      clearPending: true,
    ));
  }

  /// Re-snap one corner while keeping the fit (drift fix, §2.6).
  void reSnap() {
    _session.backToSetup();
    final ranked = state.ranked;
    _set(state.copyWith(
      step: ArSetupStep.cornerB,
      returnToWork: true,
      clearSnapped: true,
      clearMatchedB: true,
      noMatchB: false,
      tooCloseB: false,
      suggestedB: ranked.isEmpty ? null : ranked.first,
    ));
    _startSnapPolling();
  }

  void saveBoardFromWork() {
    _session.backToSetup();
    _set(state.copyWith(step: ArSetupStep.leaveBoard, returnToWork: true, ghost: _ghostSpot()));
    final g = state.ghost;
    if (g != null) unawaited(_session.setPins([g]));
  }

  void fineTuneFromWork() {
    _session.backToSetup();
    _set(state.copyWith(returnToWork: true));
    startNudge();
  }

  void _finish() {
    _stopSnapPolling();
    _lockTimer?.cancel();
    _set(state.copyWith(returnToWork: false));
    _session.enterWorkspace();
  }

  /// The user asked to go straight to work while still amber ("Carry on").
  void goToWork() => _finish();
}

T? _firstWhere<T>(Iterable<T> xs, bool Function(T) test) {
  for (final x in xs) {
    if (test(x)) return x;
  }
  return null;
}

final arSetupProvider = NotifierProvider.autoDispose<ArSetupController, ArSetupState>(ArSetupController.new);
