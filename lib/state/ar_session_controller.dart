import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/ar/alignment_estimator.dart';
import '../core/ar/ar_engine.dart';
import '../core/ar/corner_matcher.dart';
import '../core/ar/marker_code.dart';
import '../core/ar/reanchor_rule.dart';
import '../core/ar/scan_overlay.dart';
import '../core/ar/vec.dart';
import 'ar_catalog_controller.dart';
import 'ar_demo_director.dart';
import 'ar_engine_bridge.dart';
import 'ar_gateway.dart';
import 'ar_prefs_controller.dart';
import 'ar_view_models.dart';
import 'providers.dart';

/// One AR session (docs/ar-bim-overlay.md §4.6, §6; ar-setup-and-gamma-parity.md
/// §2). "Native executes, Dart decides": this controller owns the engine's
/// lifetime, every observation, the 4-DoF fit, which tiles are resident,
/// what is targeted and whether the overlay is drifting. The setup flow
/// (`ArSetupController`) and the workspace (`ArWorkspaceController`) sit on
/// top and only call the methods here.
///
/// Demo mode swaps two things and nothing else: the gateway (sample
/// building) and the engine (`FakeArEngine`). Because the fake's scripted
/// sightings can't know the sample building's geometry, sightings in Demo
/// mode come from [ArDemoDirector], which projects the sample corners and
/// boards through a hidden "true" pose so the fit behaves exactly as it
/// would on site (amber after one corner, green after two, a real residual).

enum ArSessionPhase { idle, checking, unsupported, loading, running, failed }

enum ArSessionStage { setup, work }

class ArSessionArgs {
  const ArSessionArgs({
    required this.floorId,
    this.method,
    this.targetGlobalId,
    this.assetId,
    this.workOrderId,
    this.focusCode,
    this.lineages = const {},
    this.spaceName,
    this.installCode,
  });

  final String floorId;
  final ArPlaceMethod? method;
  final String? targetGlobalId;
  final String? assetId;
  final String? workOrderId;

  /// The board that opened this session (`/ar/marker/:code`), if any.
  final String? focusCode;

  /// Model lineages ticked in the models picker; empty = every ready model.
  final Set<String> lineages;

  /// The room from a work order or asset, to narrow corner A's choices.
  final String? spaceName;

  /// Installer self-check: the board this stop expects. Setup leaves
  /// not-yet-active boards to `ArInstallController` in this mode.
  final String? installCode;

  bool get hasTarget => (targetGlobalId?.isNotEmpty ?? false) || (assetId?.isNotEmpty ?? false);
}

/// A board seen by the engine this session, with its code parsed.
class ArMarkerSighting {
  const ArMarkerSighting({
    required this.seq,
    required this.code,
    required this.centreAr,
    required this.normalAr,
    required this.method,
    required this.spreadMm,
    required this.distanceM,
    required this.viewAngleDeg,
    this.anchorId,
    this.qrEdgeMm,
    this.raw,
    this.surfaceResidualMm,
  });

  final int seq;

  /// Canonical code, or null when the QR was not a FusionEco board.
  final String? code;
  final String? raw;
  final String? anchorId;
  final Vec3 centreAr;
  final Vec3 normalAr;
  final String method;
  final double spreadMm;
  final double distanceM;
  final double viewAngleDeg;

  /// The QR's measured edge, for the print-scale check (115 mm expected).
  final double? qrEdgeMm;

  /// The engine's LiDAR check of the locked centre against the wall (mm,
  /// iOS), or null.
  final double? surfaceResidualMm;

  /// §4.2 acceptance: 0.5–2.0 m, within 35° of square-on, steady.
  bool get distanceOk => distanceM >= 0.5 && distanceM <= 2.0;
  bool get squareOn => viewAngleDeg <= 35;
  bool get steady => spreadMm <= 15;
  bool get acceptable => distanceOk && squareOn && steady;

  /// Measured print scale in percent, when the engine measured the QR edge.
  double? scalePct(double expectedMm) => qrEdgeMm == null || expectedMm <= 0 ? null : qrEdgeMm! / expectedMm * 100;
}

class ArCornerSighting {
  const ArCornerSighting({required this.seq, required this.corner});
  final int seq;
  final DetectedCorner corner;
}

enum ArToastTone { info, success, warning, error }

/// "Re-check a corner or board": the fit was marked drifting because
/// tracking was lost or relocalised, or the user walked far since the last
/// reference ([ReanchorMonitor]). Shown once per [seq]; cleared by the next
/// observation. The workspace dims the model while it is set.
class ArRecheckPrompt {
  const ArRecheckPrompt({required this.seq, required this.reason, this.walkedM = 0});
  final int seq;
  final ReanchorReason reason;

  /// Metres walked since the last reference when it fired.
  final double walkedM;
}

/// A one-shot message for the screen (shown once per [seq]).
class ArToast {
  const ArToast({required this.seq, required this.key, this.args = const [], this.tone = ArToastTone.info});
  final int seq;
  final String key;
  final List<Object> args;
  final ArToastTone tone;
}

/// Structured badge facts; the widget layer words them (§2.7).
class ArBadgeInfo {
  const ArBadgeInfo({
    required this.quality,
    this.boards = 0,
    this.corners = 0,
    this.residualM = 0,
    this.nudgeM = 0,
    this.walkedSinceCheckM,
  });

  final AlignmentQuality quality;
  final int boards;
  final int corners;
  final double residualM;
  final double nudgeM;
  final double? walkedSinceCheckM;
}

class ArSessionState {
  const ArSessionState({
    this.phase = ArSessionPhase.idle,
    this.stage = ArSessionStage.setup,
    this.args,
    this.demo = false,
    this.capabilities,
    this.floor,
    this.plan,
    this.features = const [],
    this.download = const ArDownloadProgress(),
    this.tracking = 'initializing',
    this.trackingReason,
    this.observations = const [],
    this.fit,
    this.nudgeM = 0,
    this.nudgeAxisAr,
    this.cameraAr,
    this.cameraForwardAr,
    this.walkedM = 0,
    this.walkedAtCheckM = 0,
    this.target,
    this.targetOnScreen = false,
    this.targetScreen,
    this.lastMarker,
    this.lastCorner,
    this.toast,
    this.error,
    this.gridVisible = true,
    this.driftM,
    this.paused = false,
    this.pausedFor,
    this.heatOverride = false,
    this.torchOn = false,
    this.recheck,
    this.coachCode,
    this.coachSeq = 0,
    this.recordingPath,
    this.playbackPath,
    this.scan,
    this.scanChoice,
    this.thermalStatus = 0,
  });

  final ArSessionPhase phase;
  final ArSessionStage stage;
  final ArSessionArgs? args;
  final bool demo;
  final ArCapabilities? capabilities;
  final ArFloorContext? floor;
  final ArPlan? plan;
  final List<ArFeature> features;
  final ArDownloadProgress download;

  /// [ArTracking] values (`initializing | tracking | limited | paused | …`).
  final String tracking;
  final String? trackingReason;
  final List<ArObservation> observations;
  final AlignmentFit? fit;

  /// The guided single-axis nudge (§2.6), metres along [nudgeAxisAr].
  final double nudgeM;
  final Vec3? nudgeAxisAr;
  final Vec3? cameraAr;
  final Vec3? cameraForwardAr;
  final double walkedM;

  /// [walkedM] at the last observation: "checked 3 m ago".
  final double walkedAtCheckM;
  final ArFeature? target;
  final bool targetOnScreen;

  /// Target's screen position in the AR view's logical pixels (the engine's
  /// `targetScreen` event), when known.
  final (double, double)? targetScreen;
  final ArMarkerSighting? lastMarker;
  final ArCornerSighting? lastCorner;
  final ArToast? toast;

  /// Error key for [ArSessionPhase.failed] / [ArSessionPhase.unsupported].
  final String? error;
  final bool gridVisible;

  /// Last measured drift, for the "Corrected 4 cm" / "re-snap" messages.
  final double? driftM;
  final bool paused;

  /// Why AR paused itself to save power: `idle` (no movement for 2 min) or
  /// `hot` (thermal severe+). Null for a normal pause (app in background).
  final String? pausedFor;

  /// The user chose "Continue anyway" on the heat pause: no thermal
  /// auto-pause for the rest of this session, except the OS's own
  /// emergency/shutdown levels.
  final bool heatOverride;

  /// The torch as the engine last applied it ([ArSessionController.setTorch]).
  final bool torchOn;

  /// Set while the model should be re-checked (fit is `drifting`).
  final ArRecheckPrompt? recheck;

  /// The last coaching code the engine sent (`corner-no-walls`, …) and a
  /// counter bumped with each, so setup can react to a repeat.
  final String? coachCode;
  final int coachSeq;

  /// Debug builds: the MP4 this session is being recorded to, or replayed
  /// from (`docs/ar-recording-playback.md`).
  final String? recordingPath;
  final String? playbackPath;

  /// What the room scan has measured (the engine's `scan` events), or null
  /// before the first.
  final ScanProgress? scan;

  /// The user's "Show room scan" choice this session; null = automatic
  /// ([ScanOverlayPolicy]).
  final bool? scanChoice;

  /// The engine's last thermal status (0 none … 6 shutdown).
  final int thermalStatus;

  /// Whether the room-scan overlay should show now.
  bool get scanOverlayOn => ScanOverlayPolicy.show(
        userChoice: scanChoice,
        setup: stage == ArSessionStage.setup,
        locked: isLocked,
        paused: paused,
        demo: demo,
        thermalStatus: thermalStatus,
      );

  AlignmentQuality get quality => fit?.quality ?? AlignmentQuality.none;
  bool get isPlaced => quality != AlignmentQuality.none;
  bool get isLocked => quality == AlignmentQuality.locked;

  int get boardCount => observations.where((o) => o.kind == 'marker').length;
  int get cornerCount => observations.where((o) => o.kind == 'corner').length;

  /// Camera in the model, once placed.
  Vec3? get cameraTile => (fit == null || cameraAr == null || !isPlaced) ? null : fit!.arToTile(cameraAr!);

  /// Camera heading in the model's plan, once placed.
  Vec2? get forwardTileXz {
    if (fit == null || cameraForwardAr == null || !isPlaced) return null;
    final d = fit!.dirArToTile(cameraForwardAr!);
    final xz = Vec2(d.x, d.z);
    return xz.length < 1e-6 ? null : xz.normalized;
  }

  ArBadgeInfo get badge => ArBadgeInfo(
    quality: quality,
    boards: boardCount,
    corners: cornerCount,
    residualM: fit?.maxResidualM ?? 0,
    nudgeM: nudgeM,
    walkedSinceCheckM: observations.isEmpty ? null : math.max(0, walkedM - walkedAtCheckM),
  );

  ArSessionState copyWith({
    ArSessionPhase? phase,
    ArSessionStage? stage,
    ArSessionArgs? args,
    bool? demo,
    ArCapabilities? capabilities,
    ArFloorContext? floor,
    ArPlan? plan,
    List<ArFeature>? features,
    ArDownloadProgress? download,
    String? tracking,
    String? trackingReason,
    List<ArObservation>? observations,
    AlignmentFit? fit,
    bool clearFit = false,
    double? nudgeM,
    Vec3? nudgeAxisAr,
    bool clearNudgeAxis = false,
    Vec3? cameraAr,
    Vec3? cameraForwardAr,
    double? walkedM,
    double? walkedAtCheckM,
    ArFeature? target,
    bool clearTarget = false,
    bool? targetOnScreen,
    (double, double)? targetScreen,
    ArMarkerSighting? lastMarker,
    ArCornerSighting? lastCorner,
    ArToast? toast,
    String? error,
    bool clearError = false,
    bool? gridVisible,
    double? driftM,
    bool? paused,
    String? pausedFor,
    bool clearPausedFor = false,
    bool? heatOverride,
    bool? torchOn,
    ArRecheckPrompt? recheck,
    bool clearRecheck = false,
    String? coachCode,
    int? coachSeq,
    String? recordingPath,
    bool clearRecording = false,
    String? playbackPath,
    bool clearPlayback = false,
    ScanProgress? scan,
    bool? scanChoice,
    int? thermalStatus,
  }) => ArSessionState(
    phase: phase ?? this.phase,
    stage: stage ?? this.stage,
    args: args ?? this.args,
    demo: demo ?? this.demo,
    capabilities: capabilities ?? this.capabilities,
    floor: floor ?? this.floor,
    plan: plan ?? this.plan,
    features: features ?? this.features,
    download: download ?? this.download,
    tracking: tracking ?? this.tracking,
    trackingReason: trackingReason ?? this.trackingReason,
    observations: observations ?? this.observations,
    fit: clearFit ? null : (fit ?? this.fit),
    nudgeM: nudgeM ?? this.nudgeM,
    nudgeAxisAr: clearNudgeAxis ? null : (nudgeAxisAr ?? this.nudgeAxisAr),
    cameraAr: cameraAr ?? this.cameraAr,
    cameraForwardAr: cameraForwardAr ?? this.cameraForwardAr,
    walkedM: walkedM ?? this.walkedM,
    walkedAtCheckM: walkedAtCheckM ?? this.walkedAtCheckM,
    target: clearTarget ? null : (target ?? this.target),
    targetOnScreen: targetOnScreen ?? this.targetOnScreen,
    targetScreen: targetScreen ?? this.targetScreen,
    lastMarker: lastMarker ?? this.lastMarker,
    lastCorner: lastCorner ?? this.lastCorner,
    toast: toast ?? this.toast,
    error: clearError ? null : (error ?? this.error),
    gridVisible: gridVisible ?? this.gridVisible,
    driftM: driftM ?? this.driftM,
    paused: paused ?? this.paused,
    pausedFor: clearPausedFor ? null : (pausedFor ?? this.pausedFor),
    heatOverride: heatOverride ?? this.heatOverride,
    torchOn: torchOn ?? this.torchOn,
    recheck: clearRecheck ? null : (recheck ?? this.recheck),
    coachCode: coachCode ?? this.coachCode,
    coachSeq: coachSeq ?? this.coachSeq,
    recordingPath: clearRecording ? null : (recordingPath ?? this.recordingPath),
    playbackPath: clearPlayback ? null : (playbackPath ?? this.playbackPath),
    scan: scan ?? this.scan,
    scanChoice: scanChoice ?? this.scanChoice,
    thermalStatus: thermalStatus ?? this.thermalStatus,
  );
}

class ArSessionController extends AutoDisposeNotifier<ArSessionState> {
  static const _estimator = AlignmentEstimator();

  /// AR-world Y of the tracked floor (FloorPlaneEvent), or null before one.
  double? _floorAr;

  /// The tracked floor for Dart-side geometry (the wall-taps corner sits on
  /// it); null before the engine found one.
  double? get floorAr => _floorAr;

  /// Tracking losses and long walks → "Re-check a corner or board".
  final _reanchor = ReanchorMonitor();

  /// Set when [_reanchor] fired: every refit keeps the fit `drifting` until
  /// a new observation arrives (an anchor or floor refit alone would
  /// otherwise quietly clear it).
  var _needsRecheck = false;

  /// Debug builds: replay this recording instead of the camera. Survives
  /// [restart] so a Demo toggle or a retry keeps replaying the same room.
  String? _playbackFrom;

  /// A tracked plane further than this from the floor the observations imply
  /// is not the floor (a low false plane moved the model 27 cm on the first
  /// device run). Board hanging errors are a few cm; 12 cm leaves room.
  static const _floorAgreeM = 0.12;

  /// The tracked floor, if it agrees with the observations: each corner is
  /// measured on the floor, each board implies one (its model height above
  /// the model floor). With none to compare against, the plane is trusted.
  double? _floorFor(List<ArObservation> obs, double? floorTileY) {
    final f = _floorAr;
    if (f == null || floorTileY == null || obs.isEmpty) return f;
    final implied = [for (final o in obs) o.aAr.y - (o.bTile.y - floorTileY)]..sort();
    final median = implied[implied.length ~/ 2];
    if ((f - median).abs() <= _floorAgreeM) return f;
    if (kDebugMode) {
      debugPrint('[ar-fit] floor plane ${f.toStringAsFixed(3)} ignored: observations put the floor at ${median.toStringAsFixed(3)}');
    }
    return null;
  }

  /// One line per refit in debug builds (`adb logcat -s flutter`), so an
  /// overlay that sits wrong can be read off in numbers: what each reference
  /// was seen at, where the model says it is, and how far apart they land.
  void _logFit(AlignmentFit fit, List<ArObservation> obs, _RefitReason reason) {
    if (!kDebugMode) return;
    String v(Vec3 p) => '(${p.x.toStringAsFixed(3)}, ${p.y.toStringAsFixed(3)}, ${p.z.toStringAsFixed(3)})';
    final lines = <String>[
      '[ar-fit] ${reason.name}: $fit floorAr=${_floorAr?.toStringAsFixed(3)}',
      for (final o in obs)
        '[ar-fit]   ${o.kind} ${o.id} ${o is MarkerObs ? o.method : (o as CornerObs).method}'
            '${o is CornerObs && o.baselineM != null ? '+baseline ${o.baselineM!.toStringAsFixed(1)}m' : ''} '
            'ar=${v(o.aAr)} tile=${v(o.bTile)} '
            'res=${((fit.residualsM[o.id] ?? 0) * 1000).toStringAsFixed(0)}mm '
            'dy=${((fit.verticalErrorsM[o.id] ?? 0) * 1000).toStringAsFixed(0)}mm'
            '${o is MarkerObs ? ' nAr=${v(o.normalAr)} nTile=${v(o.normalTile)}' : ''}',
    ];
    for (final l in lines) {
      debugPrint(l);
    }
  }
  static final _residency = makeResidency();

  ArEngine? _engine;
  ArGateway? _gateway;
  ArDemoDirector? _director;
  StreamSubscription<ArEvent>? _events;
  Timer? _demoDriftTimer;
  var _disposed = false;
  var _seq = 0;
  var _startToken = 0;

  /// Completed when the native platform view exists: the engine's session
  /// runs inside that view, so `startSession` waits for it (with a timeout,
  /// so a slow device still gets an error screen rather than a hang).
  Completer<void>? _viewReady;

  /// Called by the AR view's `onPlatformViewCreated`.
  void onViewCreated(int id) {
    final c = _viewReady;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Native anchor → observation id, so an anchor refinement refits.
  final _anchorToObs = <String, String>{};
  final _loadedTiles = <String>{};
  var _residencyBusy = false;
  Vec3? _residencyAtCamera;
  double? _lockedResidualM;
  var _reportedLock = false;
  DateTime _lastPoseAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ---- power (device test 2026-09-27: the phone ran hot in AR) ----
  /// No movement for this long pauses AR ("tap to resume").
  static const idlePause = Duration(minutes: 2);
  DateTime _lastMoveAt = DateTime.now();
  Vec3? _moveRefPos;
  Vec3? _moveRefFwd;
  Timer? _idleTimer;

  /// Moving 5 cm or turning ~5° counts as use; a phone lying on a table
  /// doesn't.
  void _noteMovement(Vec3 cam, Vec3 forward) {
    final p = _moveRefPos;
    final f = _moveRefFwd;
    final turned = f == null || forward.normalized.dot(f.normalized) < 0.996;
    if (p == null || p.distanceTo(cam) >= 0.05 || turned) {
      _moveRefPos = cam;
      _moveRefFwd = forward;
      _lastMoveAt = DateTime.now();
    }
    _idleTimer ??= Timer.periodic(const Duration(seconds: 10), (_) {
      if (_disposed || state.paused || state.demo) return;
      if (DateTime.now().difference(_lastMoveAt) >= idlePause) unawaited(_powerPause('idle'));
    });
  }

  Future<void> _powerPause(String why) async {
    _set(state.copyWith(pausedFor: why));
    await pause();
  }

  /// The AR view's size in logical pixels (set by the screen's layout):
  /// `pick` and `detectCornerAt` take view pixels.
  Size viewSize = const Size(390, 844);

  ArEngine? get engine => _engine;
  ArGateway? get gateway => _gateway;
  ArDemoDirector? get director => _director;

  @override
  ArSessionState build() {
    ref.onDispose(_teardown);
    ref.listen(arPrefsProvider.select((p) => p.sunlight), (_, _) {
      _onSunlightChanged();
      _syncScanOverlay();
    });
    return const ArSessionState();
  }

  void _set(ArSessionState next) {
    if (_disposed) return;
    state = next;
    _syncScanOverlay();
  }

  /// What the engine was last told about the room-scan overlay (on,
  /// contrast); re-sent only when it changes.
  (bool, bool)? _scanSent;

  /// Keeps the engine's room-scan overlay in step with [ScanOverlayPolicy]:
  /// called on every state change, sends only a change.
  void _syncScanOverlay() {
    final e = _engine;
    if (e == null || state.phase != ArSessionPhase.running) return;
    final want = (state.scanOverlayOn, ref.read(arPrefsProvider).sunlight);
    if (want == _scanSent) return;
    _scanSent = want;
    unawaited(e.setScanOverlay(want.$1, contrast: want.$2).catchError((_) => false));
  }

  /// Menu → View → "Show room scan": flips what is showing now and keeps
  /// that choice for the rest of the session.
  void toggleRoomScan() => _set(state.copyWith(scanChoice: !state.scanOverlayOn));

  /// Rings where [o] was just confirmed, green or amber by the engine's
  /// LiDAR check of the sighting it came from (blue when there was none).
  void _pulseFor(ArObservation o) {
    final e = _engine;
    if (e == null || state.demo) return;
    double? residual;
    Vec3? normal;
    final m = state.lastMarker;
    final c = state.lastCorner;
    if (o.kind == 'marker' && m != null && m.centreAr.distanceTo(o.aAr) < 0.05) {
      residual = m.surfaceResidualMm;
      normal = m.normalAr;
    } else if (o.kind == 'corner' && c != null && c.corner.posAr.distanceTo(o.aAr) < 0.05) {
      residual = c.corner.surfaceResidualMm;
    }
    final tone = SurfaceCheck.tone(residual);
    unawaited(e.pulseAt(o.aAr, normalAr: normal ?? const Vec3(0, 1, 0), tone: tone).catchError((_) => false));
    if (tone == 'warn') {
      toast('ar.verify.mismatch', args: [((residual!.abs()) / 10).round()], tone: ArToastTone.warning);
    }
  }

  void toast(String key, {List<Object> args = const [], ArToastTone tone = ArToastTone.info}) {
    _set(state.copyWith(toast: ArToast(seq: ++_seq, key: key, args: args, tone: tone)));
  }

  // ---------------------------------------------------------------- start

  /// Opens (or re-opens, after a Demo toggle) the session for [args].
  Future<void> start(ArSessionArgs args) async {
    final token = ++_startToken;
    await _stopEngine();
    _scanSent = null;
    _anchorToObs.clear();
    _loadedTiles.clear();
    _lockedResidualM = null;
    _reportedLock = false;
    _reanchor.reset();
    _needsRecheck = false;
    _floorAr = null;
    _set(ArSessionState(
      phase: ArSessionPhase.checking,
      args: args,
      tracking: ArTracking.initializing,
      playbackPath: _playbackFrom,
    ));
    await ref.read(arPrefsProvider.notifier).ready;
    if (_disposed || token != _startToken) return;
    final demo = ref.read(arPrefsProvider).demo;
    // Demo mode never replays a recording (the fake engine has no camera).
    _set(state.copyWith(demo: demo, clearPlayback: demo));

    final engine = demo ? makeFakeEngine() : ref.read(arEngineProvider);
    _engine = engine;
    _gateway = ref.read(arGatewayProvider);

    ArCapabilities caps;
    try {
      caps = await engine.capabilities();
    } catch (_) {
      caps = unsupportedCapabilities('engine-not-installed');
    }
    if (_disposed || token != _startToken) return;
    if (!caps.supported && !demo) {
      _set(state.copyWith(phase: ArSessionPhase.unsupported, capabilities: caps, error: caps.reason ?? 'unsupported'));
      return;
    }
    _viewReady = Completer<void>();
    _set(state.copyWith(phase: ArSessionPhase.loading, capabilities: caps));

    // Floor first: the setup screens need its corners and boards.
    ArFloorContext floor;
    try {
      floor = await _gateway!.floorContext(args.floorId, focusCode: args.focusCode);
    } catch (e) {
      if (_disposed || token != _startToken) return;
      _set(state.copyWith(phase: ArSessionPhase.failed, error: arErrorKey(e)));
      return;
    }
    if (_disposed || token != _startToken) return;
    floor = _filterLineages(floor, args.lineages);
    _director = demo ? ArDemoDirector(floor: floor) : null;

    _events = engine.events.listen(_onEvent, onError: (_) {});
    if (!demo) {
      // The screen builds the native view once capabilities say "supported".
      await _viewReady!.future.timeout(const Duration(seconds: 4), onTimeout: () {});
      if (_disposed || token != _startToken) return;
    }
    try {
      await engine.startSession(playbackFrom: demo ? null : _playbackFrom);
    } catch (e) {
      if (_disposed || token != _startToken) return;
      _set(state.copyWith(phase: ArSessionPhase.failed, error: arErrorKey(e)));
      return;
    }
    if (_disposed || token != _startToken) return;

    _set(state.copyWith(phase: ArSessionPhase.running, floor: floor, tracking: demo ? ArTracking.tracking : state.tracking));

    // Everything below streams in while the user starts aligning (§7 rule 4).
    unawaited(_loadPlan(floor, token));
    unawaited(_loadFeatures(floor, args, token));
    unawaited(_download(floor, token));
    unawaited(_pushGridLines());
  }

  /// Re-runs [start] with the same arguments (after toggling Demo mode).
  Future<void> restart() async {
    final args = state.args;
    if (args != null) await start(args);
  }

  ArFloorContext _filterLineages(ArFloorContext f, Set<String> lineages) {
    if (lineages.isEmpty) return f;
    final builds = f.builds.where((b) => lineages.contains(b.lineage)).toList();
    if (builds.isEmpty) return f;
    final ids = builds.map((b) => b.buildId).toSet();
    return ArFloorContext(
      buildingId: f.buildingId,
      buildingName: f.buildingName,
      floorId: f.floorId,
      floorName: f.floorName,
      builds: builds,
      tiles: f.tiles.where((t) => ids.contains(arTileBuildId(t))).toList(),
      markers: f.markers,
      corners: f.corners,
      gridLines: f.gridLines,
      floorFinishOffsetM: f.floorFinishOffsetM,
      floorDatumY: f.floorDatumY,
      totalBytes: f.tiles.where((t) => ids.contains(arTileBuildId(t))).fold<int>(0, (s, t) => s + arTileBytes(t)),
      focusBytes: f.focusBytes,
      fromCache: f.fromCache,
    );
  }

  Future<void> _loadPlan(ArFloorContext floor, int token) async {
    try {
      final plan = await _gateway!.floorPlan(floor.floorId);
      if (_disposed || token != _startToken || plan == null) return;
      _set(state.copyWith(plan: plan));
    } catch (_) {
      // The mini plan is a guide; setup still works from the corner list.
    }
  }

  Future<void> _loadFeatures(ArFloorContext floor, ArSessionArgs args, int token) async {
    try {
      final features = await _gateway!.features(floor);
      if (_disposed || token != _startToken) return;
      ArFeature? target;
      for (final f in features) {
        final byGlobal = args.targetGlobalId != null && f.globalId == args.targetGlobalId;
        final byAsset = args.assetId != null && f.assetId == args.assetId;
        if (byGlobal || byAsset) {
          target = f;
          break;
        }
      }
      _set(state.copyWith(features: features, target: target));
      if (target != null) await setTargetFeature(target);
      if (args.hasTarget && target == null) {
        toast('ar.toast.target_not_in_model', tone: ArToastTone.warning);
      }
    } catch (_) {
      // Picking and Locate need features; the overlay itself doesn't.
      toast('ar.toast.features_unavailable', tone: ArToastTone.warning);
    }
  }

  Future<void> _download(ArFloorContext floor, int token) async {
    try {
      await _gateway!.download(
        floor,
        onProgress: (p) {
          if (_disposed || token != _startToken) return;
          final wasFocusReady = state.download.focusReady && state.download.focusTotalBytes > 0;
          _set(state.copyWith(download: p));
          if (p.focusReady && !wasFocusReady) unawaited(_updateResidency(force: true));
        },
      );
      if (_disposed || token != _startToken) return;
      _set(state.copyWith(download: ArDownloadProgress(
        focusDoneBytes: state.download.focusTotalBytes,
        focusTotalBytes: state.download.focusTotalBytes,
        doneBytes: state.download.totalBytes,
        totalBytes: state.download.totalBytes,
        done: true,
      )));
      unawaited(_updateResidency(force: true));
    } catch (e) {
      if (_disposed || token != _startToken) return;
      _set(state.copyWith(download: ArDownloadProgress(
        focusDoneBytes: state.download.focusDoneBytes,
        focusTotalBytes: state.download.focusTotalBytes,
        doneBytes: state.download.doneBytes,
        totalBytes: state.download.totalBytes,
        error: arErrorKey(e),
      )));
      // Whatever is local still renders.
      unawaited(_updateResidency(force: true));
    }
  }

  // --------------------------------------------------------------- events

  void _onEvent(ArEvent e) {
    if (_disposed) return;
    // An if-chain rather than a switch: a switch over the sealed event type
    // would stop compiling the day the engine grows a new event, and a new
    // event is always safe to ignore here.
    if (e is TrackingEvent) {
      _set(state.copyWith(tracking: e.state, trackingReason: e.reason));
      if (state.isPlaced) {
        final why = _reanchor.tracking(DateTime.now(), e.state, e.reason);
        if (why != null) _flagRecheck(why);
      }
    } else if (e is MarkerSeenEvent) {
      // Demo sightings come from the director (see the class comment).
      if (state.demo) return;
      _onMarkerSeen(
        raw: e.rawPayload,
        anchorId: e.anchorId,
        centreAr: e.centreAr,
        normalAr: e.normalAr,
        method: e.method,
        spreadMm: e.spreadMm,
        distanceM: e.distanceM,
        viewAngleDeg: e.viewAngleDeg,
        qrEdgeMm: e.qrEdgeMm,
        surfaceResidualMm: e.surfaceResidualMm,
      );
    } else if (e is CornerSeenEvent) {
      if (state.demo) return;
      _set(state.copyWith(lastCorner: ArCornerSighting(seq: ++_seq, corner: DetectedCorner.fromSeen(e))));
    } else if (e is AnchorUpdatedEvent) {
      _onAnchorUpdated(e.anchorId, e.posAr);
    } else if (e is FloorPlaneEvent) {
      if (state.demo) return;
      _floorAr = e.yAr;
      // Only a refit that already placed the model moves it; the floor alone
      // never places anything.
      if (state.observations.isNotEmpty) _refit(state.observations, reason: _RefitReason.floor);
    } else if (e is ScanProgressEvent) {
      if (state.demo) return;
      _set(state.copyWith(scan: ScanProgress.fromEvent(e)));
    } else if (e is ThermalEvent) {
      if (state.demo) return;
      _set(state.copyWith(thermalStatus: e.status));
      // Overridden: only the OS's last-resort levels (emergency, shutdown)
      // still pause; Android throttles or kills apps there anyway.
      final pauseIt = state.heatOverride ? e.status >= 5 : e.isHot;
      if (pauseIt && !state.paused) {
        unawaited(_powerPause('hot'));
      } else if (e.status == 2) {
        toast('ar.toast.warm', tone: ArToastTone.warning);
      }
    } else if (e is CameraPoseEvent) {
      // Demo: the fake's camera walks a different sample floor; the
      // director places the camera instead (see addObservation).
      if (state.demo) return;
      _onPose(e.arFromCamera);
    } else if (e is TargetScreenEvent) {
      _set(state.copyWith(targetOnScreen: e.onScreen, targetScreen: (e.x, e.y)));
    } else if (e is ArErrorEvent) {
      // Coaching codes (fe_ar CHANNEL.md "Error codes") are guidance, not
      // faults: while setup polls for a corner every 600 ms, each empty snap
      // makes the engine emit a throttled `corner-*` code, and "AR hiccup
      // (corner-no-surface)" in red would read as a failure mid-aim.
      // The session itself could not run (camera refused, sensor or session
      // failure): show the fallback screen with its next step, not a toast
      // over a frozen camera. iOS reports these as events, after start.
      if (!state.demo && _fatalCodes.contains(e.code)) {
        _set(state.copyWith(
          phase: e.code == 'camera-denied' || e.code == 'device-not-supported'
              ? ArSessionPhase.unsupported
              : ArSessionPhase.failed,
          error: e.code == 'camera-denied' || e.code == 'device-not-supported' ? e.code : 'ar.error.generic',
        ));
        return;
      }
      final coach = _coachKeyFor(e.code);
      if (coach != null) {
        _set(state.copyWith(coachCode: e.code, coachSeq: state.coachSeq + 1));
        toast(coach);
      } else {
        // Recoverable hiccups (a tile to re-download, an anchor refused):
        // plain words, never the engine's code.
        toast('ar.toast.engine_error_plain', tone: ArToastTone.warning);
      }
    }
  }

  /// Engine error codes that mean the AR session is not running at all.
  static const _fatalCodes = {'camera-denied', 'camera-unavailable', 'session-failed', 'device-not-supported', 'renderer-failed'};

  static String? _coachKeyFor(String code) => switch (code) {
        'corner-no-surface' || 'corner-not-found' => 'ar.corner.coach',
        // Plain painted walls: ARCore tracks no vertical plane at all. Say
        // what works instead (setup offers the wall-taps corner).
        'corner-no-walls' => 'ar.corner.coach_no_walls',
        'corner-no-floor' => 'ar.coach.floor',
        'corner-not-tracking' => 'ar.coach.tracking',
        'marker-unstable' => 'ar.lock.hold_still',
        _ => null,
      };

  void _onMarkerSeen({
    required String raw,
    required Vec3 centreAr,
    required Vec3 normalAr,
    required String method,
    required double spreadMm,
    required double distanceM,
    required double viewAngleDeg,
    String? anchorId,
    double? qrEdgeMm,
    double? surfaceResidualMm,
  }) {
    _set(state.copyWith(
      lastMarker: ArMarkerSighting(
        seq: ++_seq,
        code: MarkerCode.fromScan(raw),
        raw: raw,
        anchorId: anchorId,
        centreAr: centreAr,
        normalAr: normalAr,
        method: method,
        spreadMm: spreadMm,
        distanceM: distanceM,
        viewAngleDeg: viewAngleDeg,
        qrEdgeMm: qrEdgeMm,
        surfaceResidualMm: surfaceResidualMm,
      ),
    ));
  }

  /// Demo mode: a board sighting synthesised by [ArDemoDirector].
  void injectDemoMarker(ArMarkerSighting s) {
    _set(state.copyWith(lastMarker: ArMarkerSighting(
      seq: ++_seq,
      code: s.code,
      raw: s.raw,
      anchorId: s.anchorId,
      centreAr: s.centreAr,
      normalAr: s.normalAr,
      method: s.method,
      spreadMm: s.spreadMm,
      distanceM: s.distanceM,
      viewAngleDeg: s.viewAngleDeg,
      qrEdgeMm: s.qrEdgeMm,
    )));
  }

  /// Demo mode: a corner snap synthesised by [ArDemoDirector].
  void injectDemoCorner(DetectedCorner corner) {
    _set(state.copyWith(lastCorner: ArCornerSighting(seq: ++_seq, corner: corner)));
  }

  void _onPose(Mat4 arFromCamera) {
    final now = DateTime.now();
    final m = arFromCamera.toList();
    final cam = Vec3(m[12], m[13], m[14]);
    // Camera looks down its −Z axis.
    final forward = Vec3(-m[8], -m[9], -m[10]);
    final prev = state.cameraAr;
    final step = prev == null ? 0.0 : prev.distanceXzTo(cam);
    _noteMovement(cam, forward);
    // A tracking jump (relocalisation) is not walking.
    final walked = state.walkedM + (step < 3 ? step : 0);
    if (now.difference(_lastPoseAt) < const Duration(milliseconds: 180) && step < 0.05) return;
    _lastPoseAt = now;
    _set(state.copyWith(cameraAr: cam, cameraForwardAr: forward, walkedM: walked));
    if (state.isPlaced && state.observations.isNotEmpty) {
      final why = _reanchor.walked(walked - state.walkedAtCheckM);
      if (why != null) _flagRecheck(why);
    }
    unawaited(_updateResidency());
  }

  /// Marks the fit drifting and prompts a re-check (Rules in
  /// [ReanchorMonitor]). The model is not moved: only a new corner or board
  /// can say where it should be.
  void _flagRecheck(ReanchorReason why) {
    final fit = state.fit;
    if (fit == null || !fit.isPlaced) return;
    _needsRecheck = true;
    final walked = math.max(0.0, state.walkedM - state.walkedAtCheckM);
    _set(state.copyWith(
      fit: fit.withQuality(AlignmentQuality.drifting),
      recheck: ArRecheckPrompt(seq: ++_seq, reason: why, walkedM: walked),
    ));
    if (kDebugMode) debugPrint('[ar-fit] re-check: ${why.name} (walked ${walked.toStringAsFixed(1)} m)');
    toast(
      switch (why) {
        ReanchorReason.walkedFar => 'ar.recheck.walked',
        ReanchorReason.relocalized => 'ar.recheck.relocalized',
        ReanchorReason.trackingLost => 'ar.recheck.tracking_lost',
      },
      args: why == ReanchorReason.walkedFar ? [walked.round()] : const [],
      tone: ArToastTone.warning,
    );
  }

  /// Pins a native anchor under a committed corner, so the tracker's map
  /// corrections move the observation (and the model) with the real corner.
  /// Boards get theirs from the engine; corners had none, and in a plain room
  /// the model slid whenever ARCore corrected its map (first device run).
  Future<void> anchorObservation(ArObservation o) async {
    final e = _engine;
    if (e == null || state.demo) return;
    final id = await e.anchorAt(o.aAr);
    if (id != null && !_disposed) _anchorToObs[id] = o.id;
  }

  /// The tracker refined a board's anchor: refit, and watch for drift.
  void _onAnchorUpdated(String anchorId, Vec3 posAr) {
    final obsId = _anchorToObs[anchorId];
    if (obsId == null) return;
    final obs = [
      for (final o in state.observations) o.id == obsId ? o.withAr(posAr) : o,
    ];
    _refit(obs, reason: _RefitReason.anchor);
  }

  // --------------------------------------------------------- observations

  /// Adds (or replaces, by id) an observation and refits. Returns the fit.
  AlignmentFit addObservation(ArObservation o, {String? anchorId}) {
    final walked = state.walkedM;
    final obs = [
      for (final x in state.observations)
        if (x.id != o.id) x.withDistanceSince(math.max(0, walked - state.walkedAtCheckM) + x.distanceSinceM),
      o,
    ];
    if (anchorId != null) _anchorToObs[anchorId] = o.id;
    _pulseFor(o);
    _reanchor.reset();
    _needsRecheck = false;
    _set(state.copyWith(walkedAtCheckM: walked, clearRecheck: true));
    final director = _director;
    if (state.demo && director != null) {
      // Stand where a person would to see it, facing it; the walk between
      // sightings counts toward "checked 3 m ago".
      final (cam, fwd) = director.cameraFor(o);
      final prev = state.cameraAr;
      final step = prev == null ? 0.0 : prev.distanceXzTo(cam);
      _set(state.copyWith(cameraAr: cam, cameraForwardAr: fwd, walkedM: state.walkedM + step, walkedAtCheckM: state.walkedM + step));
    }
    return _refit(obs, reason: _RefitReason.observation);
  }

  /// Starts over: every observation and nudge dropped ("Re-align").
  void resetAlignment() {
    _anchorToObs.clear();
    _lockedResidualM = null;
    _reanchor.reset();
    _needsRecheck = false;
    _set(ArSessionState(
      phase: state.phase,
      stage: ArSessionStage.setup,
      args: state.args,
      demo: state.demo,
      capabilities: state.capabilities,
      floor: state.floor,
      plan: state.plan,
      features: state.features,
      download: state.download,
      tracking: state.tracking,
      cameraAr: state.cameraAr,
      cameraForwardAr: state.cameraForwardAr,
      walkedM: state.walkedM,
      target: state.target,
      gridVisible: state.gridVisible,
      torchOn: state.torchOn,
      recordingPath: state.recordingPath,
      playbackPath: state.playbackPath,
      heatOverride: state.heatOverride,
      scan: state.scan,
      scanChoice: state.scanChoice,
      thermalStatus: state.thermalStatus,
    ));
  }

  AlignmentFit _refit(List<ArObservation> obs, {required _RefitReason reason}) {
    final before = state.fit;
    final nudgeAr = (state.nudgeM != 0 && state.nudgeAxisAr != null) ? state.nudgeAxisAr! * state.nudgeM : null;
    final floor = state.floor;
    final floorTileY = floor == null ? null : floor.floorDatumY + floor.floorFinishOffsetM;
    var fit = obs.isEmpty
        ? AlignmentFit.none()
        : _estimator.fit(
            obs,
            nudgeAr: nudgeAr,
            floorAr: _floorFor(obs, floorTileY),
            floorTileY: floorTileY,
          );
    _logFit(fit, obs, reason);

    if (_needsRecheck && reason != _RefitReason.observation && fit.isPlaced && fit.quality != AlignmentQuality.manual) {
      // Still waiting for the re-check: an anchor or floor refit must not
      // turn the badge back to a calm amber or green.
      fit = fit.withQuality(AlignmentQuality.drifting);
    }

    if (reason == _RefitReason.anchor && _lockedResidualM != null && fit.quality == AlignmentQuality.locked) {
      // Runtime drift check: the anchors moved apart since the lock.
      final growth = fit.maxResidualM - _lockedResidualM!;
      if (growth > 0.03) {
        fit = fit.withQuality(AlignmentQuality.drifting);
        _set(state.copyWith(driftM: growth));
        toast('ar.toast.drifting', args: [(growth * 100).round()], tone: ArToastTone.warning);
      }
    }

    if (fit.quality == AlignmentQuality.locked) {
      _lockedResidualM ??= fit.maxResidualM;
    }
    if (fit.outliers.isNotEmpty && (before?.outliers.length ?? 0) < fit.outliers.length) {
      toast('ar.toast.outlier_dropped', args: [fit.outliers.last], tone: ArToastTone.warning);
    }

    _set(state.copyWith(observations: obs, fit: fit));
    unawaited(_pushTransform(fit, ease: before?.isPlaced ?? false));
    if (fit.quality == AlignmentQuality.locked && !_reportedLock) {
      _reportedLock = true;
      unawaited(_reportAlignment());
    }
    unawaited(_updateResidency(force: before?.isPlaced != true));
    return fit;
  }

  Future<void> _pushTransform(AlignmentFit fit, {required bool ease}) async {
    final e = _engine;
    if (e == null || !fit.isPlaced) return;
    try {
      // Re-alignment eases in and never snaps (§4.3).
      await e.setModelTransform(fit.arFromTile, easeMs: ease ? 300 : 0);
    } catch (_) {}
  }

  // ---------------------------------------------------------------- nudge

  /// Starts a guided nudge. The axis follows where the user stands (§2.6):
  /// facing along a wall, the model moves only toward or away from it, i.e.
  /// along the horizontal perpendicular of the view direction.
  void beginNudge() {
    final f = state.cameraForwardAr;
    Vec3 axis;
    if (f == null || Vec2(f.x, f.z).length < 1e-3) {
      // No pose yet: nudge across the first observation's wall/face.
      axis = _fallbackNudgeAxis();
    } else {
      final h = Vec2(f.x, f.z).normalized;
      axis = Vec3(-h.y, 0, h.x);
    }
    _set(state.copyWith(nudgeAxisAr: axis));
  }

  Vec3 _fallbackNudgeAxis() {
    for (final o in state.observations) {
      if (o is MarkerObs) return Vec3(o.normalAr.x, 0, o.normalAr.z).normalized;
      if (o is CornerObs) return Vec3(o.faceAAr.x, 0, o.faceAAr.y).normalized;
    }
    return const Vec3(1, 0, 0);
  }

  /// One tap of − or + (5 mm per tap in the UI).
  void nudgeBy(double deltaM) {
    if (state.nudgeAxisAr == null) beginNudge();
    final next = (state.nudgeM + deltaM).clamp(-0.5, 0.5).toDouble();
    _set(state.copyWith(nudgeM: next));
    _refit(state.observations, reason: _RefitReason.nudge);
  }

  void clearNudge() {
    _set(state.copyWith(nudgeM: 0, clearNudgeAxis: true));
    _refit(state.observations, reason: _RefitReason.nudge);
  }

  // -------------------------------------------------------------- stages

  void enterWorkspace() {
    _set(state.copyWith(stage: ArSessionStage.work));
    // Placed: depth only served setup (corner snaps, wall taps). Off saves
    // a good share of the session's CPU/GPU; back on when setup returns.
    unawaited(_engine?.setDepth(false));
    if (state.demo) _armDemoDrift();
  }

  void backToSetup() {
    _set(state.copyWith(stage: ArSessionStage.setup));
    unawaited(_engine?.setDepth(true));
  }

  /// Demo only: one honest drift after a minute of work, so the re-snap
  /// prompt can be tried (the fake engine's own drift can't move the
  /// director's synthetic anchors).
  void _armDemoDrift() {
    _demoDriftTimer?.cancel();
    _demoDriftTimer = Timer(const Duration(seconds: 75), () {
      if (_disposed || !state.isLocked || state.stage != ArSessionStage.work) return;
      _set(state.copyWith(fit: state.fit!.withQuality(AlignmentQuality.drifting), driftM: 0.04));
      toast('ar.toast.drifting', args: [4], tone: ArToastTone.warning);
    });
  }

  // ---------------------------------------------------------------- tiles

  /// Resident set = target tiles + tiles within 15 m of the camera, closest
  /// first, within the triangle budget; 3 m hysteresis (§6.5).
  Future<void> _updateResidency({bool force = false}) async {
    final e = _engine;
    final floor = state.floor;
    if (e == null || floor == null || floor.tiles.isEmpty || _residencyBusy) return;
    if (!state.download.focusReady && !state.download.done && !floor.fromCache) return;
    final centre = state.cameraTile ?? _focusPoint();
    if (centre == null) return;
    final last = _residencyAtCamera;
    final cam = state.cameraAr;
    if (!force && last != null && cam != null && last.distanceXzTo(cam) < 2) return;
    _residencyBusy = true;
    try {
      final pinned = _targetTileHashes();
      final plan = _residency.plan(
        cameraTile: centre,
        tiles: floor.tiles,
        loaded: Set<String>.of(_loadedTiles),
        pinned: pinned,
      );
      if (plan.unload.isNotEmpty) {
        await e.unloadTiles(plan.unload);
        _loadedTiles.removeAll(plan.unload);
      }
      if (plan.load.isNotEmpty) {
        // Only tiles already on the phone: the rest arrive with the download
        // and the next residency pass picks them up.
        final paths = await _gateway!.tilePaths(plan.load);
        final refs = [for (final entry in paths.entries) makeTileRef(entry.key, entry.value)];
        if (refs.isNotEmpty) {
          await e.loadTiles(refs);
          _loadedTiles.addAll(paths.keys);
        }
      }
      _residencyAtCamera = state.cameraAr;
    } catch (_) {
      // A tile that fails to load is retried on the next move.
    } finally {
      _residencyBusy = false;
    }
  }

  /// Before the model is placed: the focus board, else the target, else the
  /// middle of the floor's tiles.
  Vec3? _focusPoint() {
    final floor = state.floor;
    if (floor == null) return null;
    final code = state.args?.focusCode;
    if (code != null) {
      final m = floor.markerByCode(code);
      if (m != null) return m.posTile;
    }
    if (state.target != null) return state.target!.centre;
    if (floor.corners.isNotEmpty) return floor.corners.first.posTile;
    if (floor.tiles.isEmpty) return null;
    return arTileCentre(floor.tiles.first);
  }

  Set<String> _targetTileHashes() => state.target?.tileHashes ?? const {};

  // --------------------------------------------------------- engine calls

  Future<void> setTargetFeature(ArFeature? f) async {
    _set(f == null ? state.copyWith(clearTarget: true, targetOnScreen: false) : state.copyWith(target: f));
    try {
      // buildId: feature ids are dense per build, so the id alone would
      // union the target's bounds with another build's namesake.
      await _engine?.setTarget(f == null ? null : [f.featureId], buildId: f?.buildId);
    } catch (_) {}
    unawaited(_updateResidency(force: true));
  }

  /// The last layers sent, re-sent when Sunlight mode flips.
  ({bool mep, bool structure, bool architecture, double opacity, double? sectionY})? _lastLayers;

  Future<void> setLayers({
    required bool mep,
    required bool structure,
    required bool architecture,
    required double opacity,
    double? sectionY,
  }) async {
    _lastLayers = (mep: mep, structure: structure, architecture: architecture, opacity: opacity, sectionY: sectionY);
    try {
      await _engine?.setLayers(makeLayerState(
        mep: mep,
        structure: structure,
        architecture: architecture,
        opacity: opacity,
        sectionY: sectionY,
        // Sunlight mode also strengthens the model itself (native `contrast`).
        contrast: ref.read(arPrefsProvider).sunlight,
      ));
    } catch (_) {}
  }

  void _onSunlightChanged() {
    final l = _lastLayers;
    if (l == null) return;
    unawaited(setLayers(mep: l.mep, structure: l.structure, architecture: l.architecture, opacity: l.opacity, sectionY: l.sectionY));
  }

  /// One build's feature-state texture ([buildId] scopes it; see
  /// [ArEngine.setFeatureState]).
  Future<void> setFeatureState(Uint8List rgba, int width, {String? buildId}) async {
    try {
      await _engine?.setFeatureState(rgba, width, buildId: buildId);
    } catch (_) {}
  }

  Future<void> setGridVisible(bool visible) async {
    _set(state.copyWith(gridVisible: visible));
    await _pushGridLines();
  }

  Future<void> _pushGridLines() async {
    final floor = state.floor;
    final e = _engine;
    if (floor == null || e == null) return;
    try {
      await e.setGridLines(
        state.gridVisible ? [for (final g in floor.gridLines) makeGridLineRef(g)] : const [],
        floor.floorDatumY + floor.floorFinishOffsetM,
      );
    } catch (_) {}
  }

  Future<void> setPins(List<ArPinSpec> pins) async {
    try {
      await _engine?.setPins([for (final p in pins) makePin(p)]);
    } catch (_) {}
  }

  /// A tap in the view → the element under it, or null. View pixels.
  Future<ArPickHit?> pick(double x, double y) async {
    final e = _engine;
    if (e == null) return null;
    try {
      final r = await e.pick(x, y);
      if (r == null) return null;
      return readPick(r);
    } catch (_) {
      return null;
    }
  }

  /// [pick] for many view points in one engine call (the lasso).
  Future<List<ArPickHit?>> pickMany(List<(double, double)> points) async {
    final e = _engine;
    if (e == null || points.isEmpty) return [for (final _ in points) null];
    try {
      final r = await e.pickMany(points);
      return [for (final p in r) p == null ? null : readPick(p)];
    } catch (_) {
      return [for (final _ in points) null];
    }
  }

  /// The measured surface point under a view point: wall taps and the
  /// long-baseline tap. Null in Demo mode (the director fakes those).
  Future<ArDepthPoint?> depthPointAt(double x, double y) async {
    final e = _engine;
    if (e == null || state.demo) return null;
    try {
      return await e.depthPointAt(x, y);
    } catch (_) {
      return null;
    }
  }

  /// Torch on/off (a dark plant room). [ArSessionState.torchOn] follows what
  /// the engine actually applied; [ArCapabilities.torch] says whether to
  /// offer it at all.
  /// Restarts autofocus (double-tap on the camera, the Focus button).
  Future<bool> refocus() async {
    final e = _engine;
    if (e == null || state.demo) return false;
    try {
      return await e.refocus();
    } catch (_) {
      return false;
    }
  }

  Future<bool> setTorch(bool on) async {
    final e = _engine;
    if (e == null) return false;
    var applied = false;
    try {
      applied = await e.setTorch(on);
    } catch (_) {}
    _set(state.copyWith(torchOn: applied ? on : false));
    return applied;
  }

  // ------------------------------------------------ recording (debug only)

  /// Where debug recordings go: app-specific external storage on Android
  /// (`adb pull /sdcard/Android/data/com.fusionapps.fieldops/files/ar_recordings/`),
  /// app documents elsewhere. `docs/ar-recording-playback.md`.
  static Future<Directory> recordingsDir() async {
    Directory? base;
    try {
      if (Platform.isAndroid) base = await getExternalStorageDirectory();
    } catch (_) {}
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/ar_recordings');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Recordings on the device, newest first.
  static Future<List<File>> listRecordings() async {
    final dir = await recordingsDir();
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.mp4')).toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  /// Debug builds: records the running session (camera, IMU, tracking) to a
  /// new MP4 until [debugStopRecording] or the session stops.
  Future<void> debugStartRecording() async {
    final e = _engine;
    if (!kDebugMode || e == null || state.demo || state.recordingPath != null) return;
    final dir = await recordingsDir();
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final path = '${dir.path}/ar_$stamp.mp4';
    final ok = await e.startRecording(path);
    if (ok) {
      _set(state.copyWith(recordingPath: path));
    } else {
      toast('ar.debug.record_failed', tone: ArToastTone.error);
    }
  }

  Future<void> debugStopRecording() async {
    final e = _engine;
    if (e == null) return;
    final path = await e.stopRecording() ?? state.recordingPath;
    _set(state.copyWith(clearRecording: true));
    if (path != null) toast('ar.debug.record_saved', args: [path.split('/').last], tone: ArToastTone.success);
  }

  /// Debug builds: restarts the session from a recording instead of the
  /// camera ([path] null: back to the live camera).
  Future<void> debugReplay(String? path) async {
    if (!kDebugMode) return;
    _playbackFrom = path;
    await restart();
  }

  /// A snap request at a view point in pixels (the pin in the middle).
  Future<DetectedCorner?> detectCornerAt(double x, double y) async {
    final e = _engine;
    if (e == null || state.demo) return null;
    try {
      final seen = await e.detectCornerAt(x, y);
      return seen == null ? null : DetectedCorner.fromSeen(seen);
    } catch (_) {
      return null;
    }
  }

  /// A screenshot with the overlay, for snags and verification.
  Future<String?> capture() async {
    try {
      return await _engine?.capture();
    } catch (_) {
      return null;
    }
  }

  Future<void> pause() async {
    _set(state.copyWith(paused: true));
    try {
      await _engine?.pause();
    } catch (_) {}
  }

  /// "Continue anyway" on the heat pause: resume and stop pausing for heat.
  Future<void> continueDespiteHeat() async {
    _set(state.copyWith(heatOverride: true));
    toast('ar.power.override_on', tone: ArToastTone.warning);
    await resume();
  }

  Future<void> resume() async {
    _lastMoveAt = DateTime.now();
    _set(state.copyWith(paused: false, clearPausedFor: true));
    try {
      await _engine?.resume();
    } catch (_) {}
  }

  // ------------------------------------------------------------- telemetry

  Future<void> _reportAlignment() async {
    final floor = state.floor;
    final fit = state.fit;
    final g = _gateway;
    if (floor == null || fit == null || g == null || !fit.isPlaced) return;
    final caps = state.capabilities;
    final tier = state.demo ? 'demo' : (caps?.tier ?? 'B');
    final report = ArAlignmentReport(
      buildingId: floor.buildingId,
      floorId: floor.floorId,
      buildIds: floor.builds.map((b) => b.buildId).toList(),
      observations: [
        for (final o in state.observations)
          {
            'kind': o.kind,
            'ref': o.id,
            'residualMm': ((fit.residualsM[o.id] ?? 0) * 1000).roundToDouble(),
            // Health's "adopt the new position" needs where each board
            // actually is according to this session's fit.
            if (o.kind == 'marker') 'posTile': fit.arToTile(o.aAr).toList(),
          },
      ],
      maxResidualMm: (fit.maxResidualM * 1000).roundToDouble(),
      method: fit.method,
      quality: fit.quality.name,
      distanceWalkedM: state.walkedM,
      deviceTier: tier,
      capturedAt: DateTime.now(),
    );
    try {
      await g.postAlignmentEvents([report]);
    } catch (_) {
      // Telemetry never interrupts the technician.
    }
  }

  Future<void> _stopEngine() async {
    await _events?.cancel();
    _events = null;
    _demoDriftTimer?.cancel();
    final e = _engine;
    _engine = null;
    if (e != null) {
      try {
        await e.stop();
      } catch (_) {}
    }
  }

  void _teardown() {
    _disposed = true;
    _idleTimer?.cancel();
    // A session that got placed reports its final state once more on exit
    // (the lock report above may have been before later observations).
    if (state.isPlaced && state.observations.isNotEmpty) unawaited(_reportAlignment());
    unawaited(_stopEngine());
  }
}

enum _RefitReason { observation, anchor, nudge, floor }

/// Error → an `ar.error.*` key with a next step on screen.
String arErrorKey(Object e) {
  final s = e.toString().toLowerCase();
  if (s.contains('offline') || s.contains('network') || s.contains('socket') || s.contains('timeout')) {
    return 'ar.error.offline';
  }
  if (s.contains('no_published_build') || s.contains('409')) return 'ar.error.no_build';
  if (s.contains('403') || s.contains('no_access')) return 'ar.error.no_access';
  if (s.contains('404')) return 'ar.error.not_found';
  return 'ar.error.generic';
}

final arSessionProvider = NotifierProvider.autoDispose<ArSessionController, ArSessionState>(
  ArSessionController.new,
);
