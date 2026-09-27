import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ar/alignment_estimator.dart' show CornerObs;
import '../core/ar/drill_check.dart';
import '../core/ar/feature_state.dart';
import '../core/c2o/c2o_asset_resolver.dart';
import '../core/ar/vec.dart';
import '../data/ar_repository.dart' show kArProgressEntity;
import '../domain/snag.dart';
import '../theme/fe_ar_colors.dart';
import '../theme/fe_colors.dart';
import 'ar_engine_extras.dart';
import 'ar_session_controller.dart';
import 'ar_view_models.dart';
import 'auth_controller.dart';
import 'providers.dart';
import 'snag_controller.dart';

/// The AR workspace (docs/ar-setup-and-gamma-parity.md §2.9, AR-58): what a
/// tap does (mode), how it selects (single, multi, lasso), what is shown
/// (layers), and the progress status of what is selected (AR-50, four-eyes).
/// One state for both layouts: the iPad rails and the phone's tab bar and
/// sheet render the same fields.
enum ArMode { locate, verify, progress, snags, forms }

enum ArSelectMode { single, multi, lasso }

enum ArPanel { none, menu, layers, more }

enum ArColourBy { discipline, progress, system, snags }

/// A queued progress write the server turned down when the queue replayed
/// (the phone only learns it from the next `GET /progress`).
const kArRefusedOnSync = 'REFUSED_ON_SYNC';

/// Section cut height above the finished floor: default and slider range.
const double kArSectionDefaultM = 1.5;
const double kArSectionMinM = 0.3;
const double kArSectionMaxM = 3.0;

int _rgbOf(Color c) => c.toARGB32() & 0xFFFFFF;

/// The model's progress tints, **the same colours as the screens' progress
/// legend** (FeArColors.installed / verified, FeColors.danger). Core's
/// `kProgressPalette` (amber / emerald) disagreed with the legend, so a
/// green "Installed" dot sat next to amber pipes — fieldops AR agent C,
/// 2026-09-27. Not-started elements are ghosted slate so progress reads.
final Map<String, int> kArProgressRgb = {
  ArProgressStatus.installed.wire: _rgbOf(FeArColors.installed),
  ArProgressStatus.verified.wire: _rgbOf(FeArColors.verified),
  ArProgressStatus.issue.wire: _rgbOf(FeColors.danger),
};

/// Not started, in Progress colouring: faint slate context.
final int kArNotStartedRgb = _rgbOf(FeArColors.notStartedDot);

class ArLayerState {
  const ArLayerState({
    this.mep = true,
    this.structure = true,
    this.architecture = true,
    this.pipes = true,
    this.ducts = true,
    this.equipment = true,
    this.cableTrays = true,
    this.wallsAsEdges = true,
    this.phaseExisting = true,
    this.phaseNew = true,
    this.phaseDemolition = false,
    this.colourBy = ArColourBy.discipline,
    this.opacity = 0.7,
    this.section = false,
    this.sectionHeightM = kArSectionDefaultM,
    this.xray = false,
    this.hiddenDisciplines = const {},
    this.solo,
  });

  final bool mep;
  final bool structure;
  final bool architecture;
  final bool pipes;
  final bool ducts;
  final bool equipment;
  final bool cableTrays;
  final bool wallsAsEdges;
  final bool phaseExisting;
  final bool phaseNew;
  final bool phaseDemolition;
  final ArColourBy colourBy;
  final double opacity;

  /// A horizontal section cut [sectionHeightM] above the finished floor:
  /// everything above it is clipped (CHANNEL.md `setLayers.sectionY`), so a
  /// cluttered ceiling void stops hiding what is at working height.
  final bool section;

  /// Where the cut sits above the finished floor (Layers panel slider,
  /// [kArSectionMinM]–[kArSectionMaxM]). 1.5 m by default: above door
  /// handles and switches, below the ceiling services. (The web's cut plan
  /// uses 1.2 m; in AR the cut is a live tool, not a drawing convention.)
  final double sectionHeightM;

  /// "Show through walls": MEP the element facts call concealed (in a wall,
  /// the floor, a slab or above the ceiling) is drawn in the highlight mode,
  /// i.e. through walls and outlined, in its own colour (§2.9 X-ray).
  final bool xray;

  /// MEP disciplines switched off in the legend ([ArDiscipline.name]s). Walls
  /// and structure are not in here: their chips drive [architecture] and
  /// [structure], the same switches the Layers panel's models use, so the
  /// legend and the panel can never disagree.
  final Set<String> hiddenDisciplines;

  /// The chip a long-press made "show only this" ([ArDiscipline.name]);
  /// tapping it again restores everything.
  final String? solo;

  /// Whether a legend chip reads as shown: its model switch is on and, for
  /// MEP, the discipline isn't filtered out.
  bool shows(ArDiscipline d) => switch (d) {
    ArDiscipline.walls => architecture,
    ArDiscipline.structure => structure,
    _ => mep && !hiddenDisciplines.contains(d.name),
  };

  bool isSolo(ArDiscipline d) => solo == d.name && shows(d);

  ArLayerState copyWith({
    bool? mep,
    bool? structure,
    bool? architecture,
    bool? pipes,
    bool? ducts,
    bool? equipment,
    bool? cableTrays,
    bool? wallsAsEdges,
    bool? phaseExisting,
    bool? phaseNew,
    bool? phaseDemolition,
    ArColourBy? colourBy,
    double? opacity,
    bool? section,
    double? sectionHeightM,
    bool? xray,
    Set<String>? hiddenDisciplines,
    String? solo,
    bool clearSolo = false,
  }) => ArLayerState(
    mep: mep ?? this.mep,
    structure: structure ?? this.structure,
    architecture: architecture ?? this.architecture,
    pipes: pipes ?? this.pipes,
    ducts: ducts ?? this.ducts,
    equipment: equipment ?? this.equipment,
    cableTrays: cableTrays ?? this.cableTrays,
    wallsAsEdges: wallsAsEdges ?? this.wallsAsEdges,
    phaseExisting: phaseExisting ?? this.phaseExisting,
    phaseNew: phaseNew ?? this.phaseNew,
    phaseDemolition: phaseDemolition ?? this.phaseDemolition,
    colourBy: colourBy ?? this.colourBy,
    opacity: opacity ?? this.opacity,
    section: section ?? this.section,
    sectionHeightM: sectionHeightM ?? this.sectionHeightM,
    xray: xray ?? this.xray,
    hiddenDisciplines: hiddenDisciplines ?? this.hiddenDisciplines,
    solo: clearSolo ? null : (solo ?? this.solo),
  );
}

class ArWorkspaceState {
  const ArWorkspaceState({
    this.mode = ArMode.locate,
    this.selectMode = ArSelectMode.single,
    this.selection = const [],
    this.panel = ArPanel.none,
    this.layers = const ArLayerState(),
    this.progress = const ArProgressSnapshot(),
    this.progressLoaded = false,
    this.progressBusy = false,
    this.rejections = const [],
    this.planInCorner = false,
    this.torch = false,
    this.torchSupported,
    this.measuring = false,
    this.measureFrom,
    this.measureM,
    this.lassoBusy = false,
    this.picking = false,
    this.lastPickMissed = false,
    this.savedViews = 0,
    this.snagPins = const [],
    this.verify,
    this.mappingConfirmed = true,
    this.legendOpen = true,
    this.drilling = false,
    this.drill,
    this.progressQueued = 0,
  });

  final ArMode mode;
  final ArSelectMode selectMode;
  final List<ArFeature> selection;
  final ArPanel panel;
  final ArLayerState layers;
  final ArProgressSnapshot progress;
  final bool progressLoaded;
  final bool progressBusy;

  /// The server (or the client's UX check) refused these: shown on the card.
  final List<ArProgressRejection> rejections;
  final bool planInCorner;
  final bool torch;

  /// Null until the engine has been asked; false once it showed it has no
  /// torch command (the button then says "coming in a later update").
  final bool? torchSupported;
  final bool measuring;
  final ArPickHit? measureFrom;
  final double? measureM;
  final bool lassoBusy;
  final bool picking;
  final bool lastPickMissed;
  final int savedViews;

  /// Live snags on this floor that map to a modelled element.
  final List<ArSnagPin> snagPins;

  /// Verify mode's AR pre-check for the selected asset (M6).
  final ArVerifyCheck? verify;

  /// "This is the element in the model" — a human confirmation of the
  /// asset ↔ element mapping (§1.2), on by default, one tap to clear.
  final bool mappingConfirmed;

  /// The discipline legend under the badge: open, or folded to one chip.
  final bool legendOpen;

  /// The Drill check tool is on (crosshair + verdict card).
  final bool drilling;

  /// Its latest reading, refreshed at most 5 times a second.
  final ArDrillReading? drill;

  /// Progress writes made offline and still in the queue: their colours are
  /// the phone's, not yet the server's (P-008 (2): a queued four-eyes
  /// refusal is only known once the queue drains).
  final int progressQueued;

  ArFeature? get primary => selection.isEmpty ? null : selection.first;

  ArWorkspaceState copyWith({
    ArMode? mode,
    ArSelectMode? selectMode,
    List<ArFeature>? selection,
    ArPanel? panel,
    ArLayerState? layers,
    ArProgressSnapshot? progress,
    bool? progressLoaded,
    bool? progressBusy,
    List<ArProgressRejection>? rejections,
    bool? planInCorner,
    bool? torch,
    bool? torchSupported,
    bool? measuring,
    ArPickHit? measureFrom,
    bool clearMeasure = false,
    double? measureM,
    bool? lassoBusy,
    bool? picking,
    bool? lastPickMissed,
    int? savedViews,
    List<ArSnagPin>? snagPins,
    ArVerifyCheck? verify,
    bool clearVerify = false,
    bool? mappingConfirmed,
    bool? legendOpen,
    bool? drilling,
    ArDrillReading? drill,
    bool clearDrill = false,
    int? progressQueued,
  }) => ArWorkspaceState(
    mode: mode ?? this.mode,
    selectMode: selectMode ?? this.selectMode,
    selection: selection ?? this.selection,
    panel: panel ?? this.panel,
    layers: layers ?? this.layers,
    progress: progress ?? this.progress,
    progressLoaded: progressLoaded ?? this.progressLoaded,
    progressBusy: progressBusy ?? this.progressBusy,
    rejections: rejections ?? this.rejections,
    planInCorner: planInCorner ?? this.planInCorner,
    torch: torch ?? this.torch,
    torchSupported: torchSupported ?? this.torchSupported,
    measuring: measuring ?? this.measuring,
    measureFrom: clearMeasure ? null : (measureFrom ?? this.measureFrom),
    measureM: clearMeasure ? null : (measureM ?? this.measureM),
    lassoBusy: lassoBusy ?? this.lassoBusy,
    picking: picking ?? this.picking,
    lastPickMissed: lastPickMissed ?? this.lastPickMissed,
    savedViews: savedViews ?? this.savedViews,
    snagPins: snagPins ?? this.snagPins,
    verify: clearVerify ? null : (verify ?? this.verify),
    mappingConfirmed: mappingConfirmed ?? this.mappingConfirmed,
    legendOpen: legendOpen ?? this.legendOpen,
    drilling: drilling ?? this.drilling,
    drill: clearDrill ? null : (drill ?? this.drill),
    progressQueued: progressQueued ?? this.progressQueued,
  );
}

/// M6's location check: where the scanned tag *is* against where the model
/// says the asset is, with the tolerance of today's lock. Never a
/// millimetre claim: "12 cm from its modelled position".
class ArVerifyCheck {
  const ArVerifyCheck({
    required this.assetId,
    this.offsetM,
    this.toleranceM = 0.35,
    this.tagAssetId,
    this.tagMatches,
    this.checking = false,
  });

  final String assetId;
  final double? offsetM;
  final double toleranceM;
  final String? tagAssetId;
  final bool? tagMatches;
  final bool checking;

  bool get measured => offsetM != null;
  bool get consistent => offsetM != null && offsetM! <= toleranceM;
  String get result => !measured ? 'unchecked' : (consistent ? 'consistent' : 'offset');
}

class ArSnagPin {
  const ArSnagPin({required this.snagId, required this.title, required this.feature});
  final String snagId;
  final String title;
  final ArFeature feature;
}

/// What the selection adds up to: "3 selected · CHW supply", "42.6 m of pipe
/// · 2 isolation valves". Quantities come from the geometry (AR-50).
class ArSelectionSummary {
  const ArSelectionSummary({
    required this.count,
    this.systemName,
    this.runLengthM = 0,
    this.valves = 0,
    this.equipment = 0,
  });

  final int count;
  final String? systemName;
  final double runLengthM;
  final int valves;
  final int equipment;

  static ArSelectionSummary of(List<ArFeature> selection) {
    var run = 0.0;
    var valves = 0;
    var equipment = 0;
    final systems = <String>{};
    for (final f in selection) {
      if (f.isRun) {
        run += f.extentM;
      } else if (f.isValve) {
        valves++;
      } else {
        equipment++;
      }
      final sys = f.systemName ?? f.systemGlobalId;
      if (sys != null) systems.add(sys);
    }
    return ArSelectionSummary(
      count: selection.length,
      systemName: systems.length == 1 ? selection.map((f) => f.systemName).whereType<String>().firstOrNullSafe : null,
      runLengthM: run,
      valves: valves,
      equipment: equipment,
    );
  }
}

/// What the Drill check shows. [notPlaced]: no fit yet, align first;
/// [noWalls]: the floor plan has no walls to test; [noHit]: the crosshair
/// isn't on a wall.
enum ArDrillStatus { notPlaced, noWalls, noHit, safe, caution, danger }

class ArDrillReading {
  const ArDrillReading({required this.status, this.hit, this.nearest, this.nearbyCount = 0});

  final ArDrillStatus status;
  final DrillHit? hit;

  /// The nearest service behind the face within 1 m, if any (also on green:
  /// "nearest service 42 cm").
  final DrillFinding<ArFeature>? nearest;

  /// Services within the caution radius, the nearest included.
  final int nearbyCount;

  ArFeature? get feature => nearest?.ref;
}

/// What the element card can say about one element from data already on
/// the phone (bounding box, floor datum, plan walls): no server call.
class ArElementFacts {
  const ArElementFacts({required this.discipline, this.feature, this.placement, this.runLengthM, this.sizeMm = const []});

  /// The element itself, for its IFC properties (Tag, Status, SiteNote).
  final ArFeature? feature;

  final ArDiscipline discipline;

  /// Heights above the finished floor and whether it is concealed. Null
  /// before the floor pack is known.
  final ServicePlacement? placement;

  /// Runs (pipe, duct, conduit, tray): the longest box side.
  final double? runLengthM;

  /// Runs: the cross-section from the box, smallest first, in mm. One value
  /// for round sections (pipe, cable: ≈ diameter), two for ducts and trays.
  final List<int> sizeMm;
}

extension _FirstOrNullSafe<T> on Iterable<T> {
  T? get firstOrNullSafe {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}

class ArWorkspaceController extends AutoDisposeNotifier<ArWorkspaceState> {
  var _disposed = false;
  String? _progressFor;
  var _lastMarkerSeq = -1;
  ArFloorContext? _floorSeen;

  static const _drill = DrillCheck();

  /// Drill check runs at most this often (5 Hz): pose events already come
  /// at ~5 Hz, and a verdict that flickers faster than it can be read helps
  /// nobody.
  static const _drillInterval = Duration(milliseconds: 200);
  Timer? _drillTimer;
  var _drillAt = DateTime.fromMillisecondsSinceEpoch(0);

  ArSessionController get _session => ref.read(arSessionProvider.notifier);
  ArSessionState get _s => ref.read(arSessionProvider);

  /// Guarded `projectTile` for the session's current engine (floating
  /// labels); rebuilt when the engine changes (a Demo toggle restarts the
  /// session).
  ArEngineExtras? _extras;
  ArEngineExtras get extras {
    final engine = _session.engine;
    final e = _extras;
    if (e != null && identical(e.engine, engine)) return e;
    return _extras = ArEngineExtras(engine);
  }

  /// Queued progress writes (globalId → the status the phone shows), checked
  /// against the server once the queue has drained (P-008 (2)).
  final _queuedProgress = <String, ArProgressStatus>{};
  String? _queuedFloor;
  ProviderSubscription<Object?>? _queueSub;

  @override
  ArWorkspaceState build() {
    // Captured now: providers can't be read while this one is disposing.
    final session = ref.read(arSessionProvider.notifier);
    ref.onDispose(() {
      _disposed = true;
      _drillTimer?.cancel();
      _queueSub?.close();
      // The torch is the engine's (camera) state: never leave it burning
      // after the workspace is gone.
      if (state.torch) {
        try {
          unawaited(session.setTorch(false).catchError((_) => false));
        } catch (_) {}
      }
    });
    ref.listen<ArSessionState>(arSessionProvider, (prev, next) {
      // Drill check follows the camera (and a refit, a new plan).
      if (state.drilling &&
          (prev == null ||
              !identical(prev.cameraAr, next.cameraAr) ||
              !identical(prev.cameraForwardAr, next.cameraForwardAr) ||
              !identical(prev.fit, next.fit) ||
              !identical(prev.plan, next.plan) ||
              !identical(prev.features, next.features))) {
        _scheduleDrill();
      }
      // A restarted session (Demo toggle, retry) brings a new floor pack:
      // nothing selected or measured on the old one carries over.
      final floor = next.floor;
      if (floor != null && !identical(floor, _floorSeen)) {
        if (_floorSeen != null) {
          _progressFor = null;
          _set(ArWorkspaceState(layers: state.layers));
        }
        _floorSeen = floor;
      }
      // Entering work with a target: Locate is the job (§1.1).
      if (prev?.stage != ArSessionStage.work && next.stage == ArSessionStage.work) {
        unawaited(_pushLayers());
        unawaited(_pushFeatureState());
        unawaited(_loadSnagPins());
        if (next.target != null && state.selection.isEmpty) {
          _set(state.copyWith(mode: ArMode.locate, selection: [next.target!]));
        }
      }
      if (prev?.features.length != next.features.length) unawaited(_loadSnagPins());
      // Drifting (the session's re-anchor rule): dim the model until a
      // corner or board re-checks it, then restore.
      if ((prev?.recheck == null) != (next.recheck == null) && next.stage == ArSessionStage.work) {
        unawaited(_pushFeatureState());
      }
      if (prev?.torchOn != next.torchOn && state.torch != next.torchOn) {
        _set(state.copyWith(torch: next.torchOn));
      }
      // Verify: any QR that isn't a board is an asset tag being checked.
      final m = next.lastMarker;
      if (m != null && m.seq != _lastMarkerSeq) {
        _lastMarkerSeq = m.seq;
        if (m.code == null && state.mode == ArMode.verify && next.stage == ArSessionStage.work) {
          unawaited(_checkTag(m));
        }
      }
    });
    final s = ref.read(arSessionProvider);
    return ArWorkspaceState(selection: s.target == null ? const [] : [s.target!]);
  }

  void _set(ArWorkspaceState next) {
    if (_disposed) return;
    state = next;
  }

  String get _me {
    if (_s.demo) return 'demo-me';
    return ref.read(authControllerProvider).session?.userId ?? '';
  }

  // ------------------------------------------------------------ modes

  void setMode(ArMode m) {
    // A mode tab also leaves Drill check: the card below is the mode's again.
    _set(state.copyWith(
      mode: m,
      panel: ArPanel.none,
      rejections: const [],
      measuring: false,
      clearMeasure: true,
      clearVerify: true,
      drilling: false,
      clearDrill: true,
    ));
    if (m == ArMode.progress) {
      unawaited(loadProgress());
      if (state.layers.colourBy != ArColourBy.progress) {
        setLayers(state.layers.copyWith(colourBy: ArColourBy.progress));
      }
    } else if (m == ArMode.snags) {
      unawaited(_loadSnagPins());
    }
    unawaited(_pushFeatureState());
  }

  void setSelectMode(ArSelectMode m) => _set(state.copyWith(selectMode: m));

  void openPanel(ArPanel p) => _set(state.copyWith(panel: state.panel == p ? ArPanel.none : p));

  void closePanel() => _set(state.copyWith(panel: ArPanel.none));

  // -------------------------------------------------------- selection

  /// A tap on the view at ([x], [y]) in logical pixels (the engine's
  /// `pick` takes view pixels). [demoHit] is Demo mode's own hit test.
  Future<void> tap(double x, double y, {ArFeature? demoHit}) async {
    if (state.measuring) {
      await _measureTap(x, y, demoHit: demoHit);
      return;
    }
    _set(state.copyWith(picking: true, lastPickMissed: false));
    ArFeature? f = demoHit;
    if (f == null && !_s.demo) {
      final hit = await _session.pick(x, y);
      f = hit == null ? null : _featureFor(hit);
    }
    if (_disposed) return;
    if (f == null) {
      _set(state.copyWith(picking: false, lastPickMissed: true));
      return;
    }
    final hitFeature = f;
    final List<ArFeature> next;
    if (state.selectMode == ArSelectMode.single) {
      next = [hitFeature];
    } else if (state.selection.any((x) => _same(x, hitFeature))) {
      next = state.selection.where((x) => !_same(x, hitFeature)).toList();
    } else {
      next = [...state.selection, hitFeature];
    }
    _set(state.copyWith(selection: next, picking: false, rejections: const []));
    unawaited(_pushFeatureState());
  }

  /// Lasso: samples the drawn polygon (view pixels) on a grid (up to ~400
  /// points) and picks them in one batched `pickMany`, so the engine needs
  /// no projection API.
  Future<void> lasso(List<(double, double)> polygon, {List<ArFeature> demoHits = const []}) async {
    if (polygon.length < 3 && demoHits.isEmpty) return;
    _set(state.copyWith(lassoBusy: true));
    final found = <ArFeature>[...demoHits];
    if (!_s.demo && polygon.length >= 3) {
      // One batched `pickMany` (the session falls back to one pick per
      // point on an older plugin), so the grid can be ~3× denser than the
      // old ~120 sequential picks and thin pipes stop slipping through.
      final samples = lassoSamples(polygon, maxSamples: 400, minStep: 12);
      final hits = await _session.pickMany(samples);
      if (_disposed) return;
      for (final hit in hits) {
        final f = hit == null ? null : _featureFor(hit);
        if (f != null && !found.any((e) => _same(e, f))) found.add(f);
      }
    }
    final merged = state.selectMode == ArSelectMode.lasso && state.selection.isNotEmpty
        ? [...state.selection, ...found.where((f) => !state.selection.any((s) => _same(s, f)))]
        : found;
    _set(state.copyWith(selection: merged, lassoBusy: false, rejections: const []));
    unawaited(_pushFeatureState());
  }

  /// A tap on a floating label: that element alone becomes the selection.
  void selectOnly(ArFeature f) {
    _set(state.copyWith(selection: [f], rejections: const []));
    unawaited(_pushFeatureState());
  }

  void clearSelection() {
    _set(state.copyWith(selection: const [], rejections: const []));
    unawaited(_pushFeatureState());
  }

  /// Select a whole system from the current element ("Trace", §3).
  void selectSystemOf(ArFeature f) {
    final sys = f.systemGlobalId;
    if (sys == null) return;
    final all = _s.features.where((x) => x.systemGlobalId == sys && x.buildId == f.buildId).toList();
    _set(state.copyWith(selection: all, selectMode: ArSelectMode.multi));
    unawaited(_pushFeatureState());
  }

  /// Make [f] the Locate target (pulsing, drawn through walls).
  Future<void> locate(ArFeature f) async {
    await _session.setTargetFeature(f);
    _set(state.copyWith(mode: ArMode.locate, selection: [f]));
    unawaited(_pushFeatureState());
  }

  ArFeature? _featureFor(ArPickHit hit) {
    for (final f in _s.features) {
      if (f.featureId == hit.featureId && (hit.buildId == null || hit.buildId == f.buildId)) return f;
    }
    return null;
  }

  static bool _same(ArFeature a, ArFeature b) => a.featureId == b.featureId && a.buildId == b.buildId;

  /// The lasso's sample grid: points inside [polygon] on a square grid whose
  /// step keeps the count near [maxSamples] and never below [minStep] px.
  static List<(double, double)> lassoSamples(
    List<(double, double)> polygon, {
    int maxSamples = 120,
    double minStep = 24,
  }) {
    if (polygon.length < 3) return const [];
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final (x, y) in polygon) {
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
    }
    final area = math.max(1.0, (maxX - minX) * (maxY - minY));
    final step = math.max(minStep, math.sqrt(area / maxSamples));
    final out = <(double, double)>[];
    for (var y = minY; y <= maxY; y += step) {
      for (var x = minX; x <= maxX; x += step) {
        if (_inside(polygon, x, y)) out.add((x, y));
      }
    }
    return out;
  }

  static bool _inside(List<(double, double)> poly, double x, double y) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final (xi, yi) = poly[i];
      final (xj, yj) = poly[j];
      if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / ((yj - yi) == 0 ? 1e-9 : (yj - yi)) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  // ------------------------------------------------------------- measure

  void toggleMeasure() {
    final wasDrilling = state.drilling;
    _set(state.copyWith(measuring: !state.measuring, clearMeasure: true, drilling: false, clearDrill: true));
    if (wasDrilling) unawaited(_pushFeatureState());
  }

  Future<void> _measureTap(double x, double y, {ArFeature? demoHit}) async {
    ArPickHit? hit;
    if (_s.demo && demoHit != null) {
      hit = ArPickHit(featureId: demoHit.featureId, buildId: demoHit.buildId, hitTile: demoHit.centre);
    } else {
      hit = await _session.pick(x, y);
    }
    if (_disposed || hit == null || hit.hitTile == null) {
      _set(state.copyWith(lastPickMissed: true));
      return;
    }
    final from = state.measureFrom;
    if (from == null || from.hitTile == null || state.measureM != null) {
      // First point (or a new measurement after a finished one).
      _set(state.copyWith(clearMeasure: true));
      _set(state.copyWith(measureFrom: hit, lastPickMissed: false));
      return;
    }
    _set(state.copyWith(measureM: from.hitTile!.distanceTo(hit.hitTile!), lastPickMissed: false));
  }

  // -------------------------------------------------------------- layers

  void setLayers(ArLayerState l) {
    _set(state.copyWith(layers: l));
    unawaited(_pushLayers());
    unawaited(_pushFeatureState());
  }

  void toggleSection() => setLayers(state.layers.copyWith(section: !state.layers.section));

  /// The section slider: moves the cut (and turns it on). [push] false
  /// while dragging updates the label only; the engine gets the value on
  /// release, not 60 channel calls a second.
  void setSectionHeight(double m, {bool push = true}) {
    final v = m.clamp(kArSectionMinM, kArSectionMaxM).toDouble();
    _set(state.copyWith(layers: state.layers.copyWith(sectionHeightM: v, section: true)));
    if (push) unawaited(_pushLayers());
  }

  /// "Show through walls" (x-ray for concealed MEP).
  void toggleXray() => setLayers(state.layers.copyWith(xray: !state.layers.xray));

  void setOpacity(double v) {
    _set(state.copyWith(layers: state.layers.copyWith(opacity: v.clamp(0.1, 1).toDouble())));
    unawaited(_pushLayers());
  }

  void togglePlanInCorner() => _set(state.copyWith(planInCorner: !state.planInCorner));

  /// Whether this device's engine can switch the torch
  /// (`ArCapabilities.torch`; the fake engine says yes so Demo can try it).
  bool get torchAvailable => _s.capabilities?.torch ?? false;

  /// Torch on the AR camera, through the session ([ArSessionState.torchOn]
  /// is what the engine actually applied). Returns false when this device
  /// or plugin has no torch; the button then says so.
  Future<bool> toggleTorch() async {
    if (!torchAvailable) {
      _set(state.copyWith(torch: false, torchSupported: false));
      return false;
    }
    final ok = await _session.setTorch(!_s.torchOn);
    if (_disposed) return ok;
    _set(state.copyWith(torch: _s.torchOn, torchSupported: true));
    return ok;
  }

  void saveView() => _set(state.copyWith(savedViews: state.savedViews + 1));

  /// The finished floor in the tile frame: where heights are measured from.
  static double _datumOf(ArSessionState s) {
    final floor = s.floor;
    return floor == null ? 0.0 : floor.floorDatumY + floor.floorFinishOffsetM;
  }

  Future<void> _pushLayers() async {
    final l = state.layers;
    final datum = _datumOf(_s);
    await _session.setLayers(
      mep: l.mep,
      structure: l.structure,
      architecture: l.architecture,
      opacity: l.opacity,
      sectionY: l.section ? datum + l.sectionHeightM : null,
    );
  }

  // --------------------------------------------------------- disciplines

  List<ArFeature>? _countsOf;
  Map<ArDiscipline, int> _counts = const {};

  /// Elements per legend chip on the loaded floor (chips with none are not
  /// shown). Cached per feature list: the legend rebuilds with every pose.
  Map<ArDiscipline, int> disciplineCounts() {
    final features = _s.features;
    if (!identical(features, _countsOf)) {
      final counts = <ArDiscipline, int>{};
      for (final f in features) {
        final d = ArDiscipline.of(f.discipline);
        counts[d] = (counts[d] ?? 0) + 1;
      }
      _countsOf = features;
      _counts = counts;
    }
    return _counts;
  }

  /// One tap on a legend chip: hide or show that discipline. Walls and
  /// Structure are the model switches of the Layers panel. Tapping the chip
  /// that is "showing only this" restores everything.
  void toggleDiscipline(ArDiscipline d) {
    final l = state.layers;
    if (l.isSolo(d)) {
      showAllDisciplines();
      return;
    }
    setDisciplineShown(d, !l.shows(d));
  }

  /// Plain show/hide (the Layers panel's switch, and a chip tap). Clears any
  /// "show only this": the user is now choosing chip by chip.
  void setDisciplineShown(ArDiscipline d, bool shown) {
    final l = state.layers;
    switch (d) {
      case ArDiscipline.walls:
        setLayers(l.copyWith(architecture: shown, clearSolo: true));
      case ArDiscipline.structure:
        setLayers(l.copyWith(structure: shown, clearSolo: true));
      default:
        if (shown && !l.mep) {
          // Every MEP chip read as hidden because the MEP model was off:
          // bring the model back with just the one that was asked for.
          setLayers(l.copyWith(
            mep: true,
            hiddenDisciplines: {for (final x in ArDiscipline.mepValues) if (x != d) x.name},
            clearSolo: true,
          ));
          return;
        }
        final hidden = {...l.hiddenDisciplines};
        if (shown) {
          hidden.remove(d.name);
        } else {
          hidden.add(d.name);
        }
        setLayers(l.copyWith(hiddenDisciplines: hidden, clearSolo: true));
    }
  }

  /// Long-press: show only [d]. Wall edges stay on unless Walls is the one
  /// soloed: they are thin, and they are the live check that the overlay
  /// still sits on the room (§5.3) — "only electrical" without them would
  /// hide a drifted alignment. A second long-press restores everything.
  void soloDiscipline(ArDiscipline d) {
    final l = state.layers;
    if (l.isSolo(d)) {
      showAllDisciplines();
      return;
    }
    setLayers(l.copyWith(
      mep: d.isMep ? true : l.mep,
      hiddenDisciplines: {for (final x in ArDiscipline.mepValues) if (x != d) x.name},
      structure: d == ArDiscipline.structure,
      architecture: true,
      solo: d.name,
    ));
  }

  void showAllDisciplines() => setLayers(state.layers.copyWith(
    mep: true,
    structure: true,
    architecture: true,
    hiddenDisciplines: const {},
    clearSolo: true,
  ));

  void toggleLegend() => _set(state.copyWith(legendOpen: !state.legendOpen));

  // ---------------------------------------------------------- element facts

  ArPlan? _wallsOf;
  List<DrillWall> _walls = const [];
  List<ArFeature>? _slabsOf;
  List<(Vec3, Vec3)> _slabs = const [];
  List<ArFeature>? _servicesOf;
  List<DrillService<ArFeature>> _services = const [];

  List<DrillWall> _wallsFor(ArPlan? plan) {
    if (!identical(plan, _wallsOf)) {
      _wallsOf = plan;
      _walls = plan == null
          ? const []
          : [
              for (var i = 0; i < plan.walls.length; i++)
                if (plan.walls[i].length >= 2) DrillWall(polyline: plan.walls[i], thicknessM: plan.wallThicknessAt(i)),
            ];
    }
    return _walls;
  }

  List<(Vec3, Vec3)> _slabsFor(List<ArFeature> features) {
    if (!identical(features, _slabsOf)) {
      _slabsOf = features;
      _slabs = [
        for (final f in features)
          if (f.ifcType.toUpperCase().contains('SLAB')) (f.bboxMin, f.bboxMax),
      ];
    }
    return _slabs;
  }

  /// Every MEP element, whatever the legend hides: a cable filtered out of
  /// the view is still in the wall.
  List<DrillService<ArFeature>> _servicesFor(List<ArFeature> features) {
    if (!identical(features, _servicesOf)) {
      _servicesOf = features;
      _services = [
        for (final f in features)
          if (ArDiscipline.of(f.discipline).isMep) DrillService(ref: f, bboxMin: f.bboxMin, bboxMax: f.bboxMax),
      ];
    }
    return _services;
  }

  /// Heights, run length, size and concealment for the element card.
  /// Concealment is judged for MEP only: a wall is always "in a wall".
  ArElementFacts factsFor(ArFeature f) {
    final s = _s;
    final d = ArDiscipline.of(f.discipline);
    ServicePlacement? placement;
    if (s.floor != null) {
      placement = _drill.place(
        bboxMin: f.bboxMin,
        bboxMax: f.bboxMax,
        floorY: _datumOf(s),
        walls: d.isMep ? _wallsFor(s.plan) : const [],
        slabs: d.isMep ? _slabsFor(s.features) : const [],
      );
      if (!d.isMep) {
        placement = ServicePlacement(zone: ServiceZone.room, bottomM: placement.bottomM, topM: placement.topM);
      }
    }
    if (!f.isRun) return ArElementFacts(discipline: d, feature: f, placement: placement);
    final sides = [
      (f.bboxMax.x - f.bboxMin.x).abs(),
      (f.bboxMax.y - f.bboxMin.y).abs(),
      (f.bboxMax.z - f.bboxMin.z).abs(),
    ]..sort();
    final t = f.ifcType.toLowerCase();
    final round = t.contains('pipe') || t.contains('conduit') || (t.contains('cable') && !t.contains('carrier'));
    return ArElementFacts(
      feature: f,
      discipline: d,
      placement: placement,
      runLengthM: sides.last,
      sizeMm: [for (final v in round ? sides.take(1) : sides.take(2)) _roundMm(v)],
    );
  }

  /// To 5 mm below 100 mm, 10 mm above: the box is only near enough.
  static int _roundMm(double m) {
    final mm = m * 1000;
    final step = mm < 100 ? 5 : 10;
    return math.max(step, (mm / step).round() * step);
  }

  // ---------------------------------------------------------- drill check

  /// Drill check on or off. Mutually exclusive with Measure (one centre
  /// tool at a time).
  void toggleDrill() {
    final on = !state.drilling;
    _set(state.copyWith(drilling: on, clearDrill: true, measuring: false, clearMeasure: true, panel: ArPanel.none));
    if (on) {
      _drillTimer?.cancel();
      _drillTimer = null;
      _drillAt = DateTime.fromMillisecondsSinceEpoch(0);
      _runDrill();
    } else {
      unawaited(_pushFeatureState());
    }
  }

  /// "Show element": leave Drill check with the nearest service selected.
  void selectFromDrill(ArFeature f) {
    _set(state.copyWith(drilling: false, clearDrill: true, mode: ArMode.locate, selection: [f], rejections: const []));
    unawaited(_pushFeatureState());
  }

  void _scheduleDrill() {
    if (_drillTimer?.isActive ?? false) return;
    final wait = _drillInterval - DateTime.now().difference(_drillAt);
    if (wait <= Duration.zero) {
      _runDrill();
    } else {
      // Trailing run: the last pose before the phone came to rest is the
      // one that must be checked.
      _drillTimer = Timer(wait, _runDrill);
    }
  }

  void _runDrill() {
    _drillTimer = null;
    if (_disposed || !state.drilling) return;
    _drillAt = DateTime.now();
    final before = state.drill?.feature;
    final reading = _readDrill(_s);
    _set(state.copyWith(drill: reading));
    final after = reading.feature;
    // Re-upload the highlight only when the nearest service changes.
    if ((before == null) != (after == null) || (before != null && after != null && !_same(before, after))) {
      unawaited(_pushFeatureState());
    }
  }

  ArDrillReading _readDrill(ArSessionState s) {
    final fit = s.fit;
    if (!s.isPlaced || fit == null) return const ArDrillReading(status: ArDrillStatus.notPlaced);
    final walls = _wallsFor(s.plan);
    if (walls.isEmpty) return const ArDrillReading(status: ArDrillStatus.noWalls);
    final cam = s.cameraTile;
    final fwd = s.cameraForwardAr;
    if (cam == null || fwd == null) return const ArDrillReading(status: ArDrillStatus.noHit);
    final r = _drill.run(
      origin: cam,
      direction: fit.dirArToTile(fwd),
      walls: walls,
      floorY: _datumOf(s),
      services: _servicesFor(s.features),
    );
    if (r.hit == null) return const ArDrillReading(status: ArDrillStatus.noHit);
    return ArDrillReading(
      status: switch (r.verdict!) {
        DrillVerdict.safe => ArDrillStatus.safe,
        DrillVerdict.caution => ArDrillStatus.caution,
        DrillVerdict.danger => ArDrillStatus.danger,
      },
      hit: r.hit,
      nearest: r.nearest,
      nearbyCount: r.findings.where((f) => f.planeDistanceM < _drill.cautionM).length,
    );
  }

  // ------------------------------------------------------------ progress

  Future<void> loadProgress({bool force = false}) async {
    final floor = _s.floor;
    final gateway = _session.gateway;
    if (floor == null || gateway == null) return;
    if (!force && _progressFor == floor.floorId && state.progressLoaded) return;
    _progressFor = floor.floorId;
    try {
      final snapshot = await gateway.progress(floor.floorId);
      if (_disposed) return;
      _set(state.copyWith(progress: snapshot, progressLoaded: true));
      unawaited(_pushFeatureState());
    } catch (_) {
      _set(state.copyWith(progressLoaded: true));
    }
  }

  /// The client-side four-eyes preview (UX only; the server decides): which
  /// selected elements a "Verified" from *me* would be refused for, and why.
  List<ArProgressRejection> verifyBlockers() {
    final me = _me;
    final out = <ArProgressRejection>[];
    for (final f in state.selection) {
      final e = state.progress.entries[f.globalId];
      final status = e?.status ?? ArProgressStatus.notStarted;
      if (status == ArProgressStatus.verified) continue;
      if (status != ArProgressStatus.installed) {
        out.add(ArProgressRejection(globalId: f.globalId, reason: 'NOT_INSTALLED'));
      } else if (e?.installedBy != null && e!.installedBy == me) {
        out.add(ArProgressRejection(globalId: f.globalId, reason: 'SECOND_PERSON_REQUIRED'));
      }
    }
    return out;
  }

  /// Marks the selection. Returns what happened, for the card's message.
  Future<ArProgressWriteResult?> setStatus(ArProgressStatus status, {String? note}) async {
    final floor = _s.floor;
    final gateway = _session.gateway;
    if (floor == null || gateway == null || state.selection.isEmpty) return null;
    final ids = state.selection.map((f) => f.globalId).toSet().toList();
    _set(state.copyWith(progressBusy: true, rejections: const []));
    final result = await gateway.setProgress(floorId: floor.floorId, globalIds: ids, status: status, note: note);
    if (_disposed) return result;
    if (result.errorCode != null) {
      // Refused outright (or failed): nothing was stored, so nothing may be
      // painted as done. It used to fall through and colour the selection.
      _set(state.copyWith(progressBusy: false));
      return result;
    }
    // Optimistic: what the server accepted (or what is queued) shows now.
    final rejected = result.rejected.map((r) => r.globalId).toSet();
    final entries = {...state.progress.entries};
    final now = DateTime.now();
    for (final id in ids) {
      if (rejected.contains(id)) continue;
      final prev = entries[id];
      entries[id] = ArProgressEntry(
        globalId: id,
        status: status,
        assetId: prev?.assetId,
        installedBy: status == ArProgressStatus.installed ? _me : prev?.installedBy,
        installedAt: status == ArProgressStatus.installed ? now : prev?.installedAt,
        verifiedBy: status == ArProgressStatus.verified ? _me : prev?.verifiedBy,
        verifiedAt: status == ArProgressStatus.verified ? now : prev?.verifiedAt,
        note: note ?? prev?.note,
      );
    }
    if (result.queued) {
      // Parked in the queue: the server may still refuse some (four-eyes)
      // inside a 200 the phone never sees. Remember what we showed and
      // compare once the queue has drained (P-008 (2)).
      if (_queuedFloor != floor.floorId) _queuedProgress.clear();
      _queuedFloor = floor.floorId;
      for (final id in ids) {
        if (!rejected.contains(id)) _queuedProgress[id] = status;
      }
      _watchQueue();
    }
    _set(state.copyWith(
      progress: _recount(entries, state.progress.total),
      progressBusy: false,
      rejections: result.rejected,
      progressQueued: _queuedProgress.length,
    ));
    unawaited(_pushFeatureState());
    return result;
  }

  /// Starts listening to the offline queue (lazily: most sessions never
  /// queue a progress write, and tests have no queue).
  void _watchQueue() {
    if (_queueSub != null) return;
    try {
      _queueSub = ref.listen<AsyncValue<int>>(queueChangedProvider, (_, next) {
        if (next.hasValue) unawaited(recheckQueuedProgress());
      });
    } catch (_) {
      // No queue in this container (a test): [recheckQueuedProgress] can
      // still be called directly.
    }
  }

  /// Once no progress write for this floor is left in the queue, re-reads
  /// the server's statuses and reports every element the phone showed as
  /// queued that the server now says otherwise (refused on replay, most
  /// often four-eyes). Returns the refused GlobalIds.
  Future<List<String>> recheckQueuedProgress() async {
    final floorId = _queuedFloor;
    if (_queuedProgress.isEmpty || floorId == null || _s.floor?.floorId != floorId) return const [];
    try {
      final pending = await ref.read(offlineDbProvider).pendingEntityIds(kArProgressEntity);
      if (pending.contains(floorId)) return const [];
    } catch (_) {
      // No DB (tests): treat the queue as drained.
    }
    if (_disposed) return const [];
    final expected = Map<String, ArProgressStatus>.of(_queuedProgress);
    _queuedProgress.clear();
    await loadProgress(force: true);
    if (_disposed) return const [];
    final refused = [
      for (final e in expected.entries)
        if (state.progress.statusOf(e.key) != e.value) e.key,
    ];
    _set(state.copyWith(
      progressQueued: 0,
      rejections: refused.isEmpty
          ? state.rejections
          : [for (final id in refused) ArProgressRejection(globalId: id, reason: kArRefusedOnSync)],
    ));
    if (refused.isNotEmpty) {
      _session.toast('ar.progress.refused_on_sync', args: [refused.length], tone: ArToastTone.error);
    }
    return refused;
  }

  ArProgressSnapshot _recount(Map<String, ArProgressEntry> entries, int total) {
    var installed = 0, verified = 0, issue = 0;
    for (final e in entries.values) {
      switch (e.status) {
        case ArProgressStatus.installed:
          installed++;
        case ArProgressStatus.verified:
          verified++;
        case ArProgressStatus.issue:
          issue++;
        case ArProgressStatus.notStarted:
          break;
      }
    }
    final features = _s.features.length;
    return ArProgressSnapshot(
      entries: entries,
      total: math.max(total, math.max(features, entries.length)),
      installed: installed,
      verified: verified,
      issue: issue,
    );
  }

  // -------------------------------------------------------------- verify

  void toggleMappingConfirmed() => _set(state.copyWith(mappingConfirmed: !state.mappingConfirmed));

  /// The element being verified: the selection, else the Locate target.
  ArFeature? get verifyTarget {
    final f = state.primary ?? _s.target;
    return f;
  }

  double get _tolerance => _s.isLocked ? 0.35 : 0.75;

  Future<void> _checkTag(ArMarkerSighting m) async {
    final f = verifyTarget;
    final fit = _s.fit;
    if (f == null || fit == null || !fit.isPlaced || f.assetId == null) return;
    _set(state.copyWith(verify: ArVerifyCheck(assetId: f.assetId!, checking: true, toleranceM: _tolerance)));
    final tagTile = fit.arToTile(m.centreAr);
    final offset = _distanceToBox(tagTile, f);
    String? tagAsset;
    try {
      final r = m.raw == null ? null : await ref.read(c2oAssetResolverProvider).resolve(m.raw!);
      if (r is C2oResolved) tagAsset = r.assetId;
    } catch (_) {}
    if (_disposed) return;
    _set(state.copyWith(
      verify: ArVerifyCheck(
        assetId: f.assetId!,
        offsetM: offset,
        toleranceM: _tolerance,
        tagAssetId: tagAsset,
        tagMatches: tagAsset == null ? null : tagAsset == f.assetId,
      ),
    ));
  }

  /// Demo: the tag is 12 cm from the modelled box and matches the register.
  void demoScanTag() {
    final f = verifyTarget;
    if (f == null || f.assetId == null) return;
    _set(state.copyWith(
      verify: ArVerifyCheck(assetId: f.assetId!, offsetM: 0.12, toleranceM: _tolerance, tagAssetId: f.assetId, tagMatches: true),
    ));
  }

  static double _distanceToBox(Vec3 p, ArFeature f) {
    double axis(double v, double lo, double hi) => v < lo ? lo - v : (v > hi ? v - hi : 0);
    final dx = axis(p.x, math.min(f.bboxMin.x, f.bboxMax.x), math.max(f.bboxMin.x, f.bboxMax.x));
    final dy = axis(p.y, math.min(f.bboxMin.y, f.bboxMax.y), math.max(f.bboxMin.y, f.bboxMax.y));
    final dz = axis(p.z, math.min(f.bboxMin.z, f.bboxMax.z), math.max(f.bboxMin.z, f.bboxMax.z));
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  // --------------------------------------------------------------- snags

  Future<void> _loadSnagPins() async {
    final floor = _s.floor;
    if (floor == null || _s.features.isEmpty) return;
    try {
      final snags = await ref.read(snagsProvider(floor.buildingId).future);
      if (_disposed) return;
      final byAsset = <String, ArFeature>{};
      for (final f in _s.features) {
        if (f.assetId != null) byAsset[f.assetId!] = f;
      }
      final pins = <ArSnagPin>[];
      for (final Snag sn in snags) {
        if (!sn.status.isLive) continue;
        if (sn.floorId != null && sn.floorId != floor.floorId) continue;
        final f = sn.assetId == null ? null : byAsset[sn.assetId!];
        if (f != null) pins.add(ArSnagPin(snagId: sn.id, title: sn.title, feature: f));
      }
      _set(state.copyWith(snagPins: pins));
      await _session.setPins([
        for (final p in pins)
          ArPinSpec(
            id: 'snag-${p.snagId}',
            posTile: Vec3(p.feature.centre.x, p.feature.bboxMax.y + 0.2, p.feature.centre.z),
            kind: 'snag',
            label: p.title,
          ),
      ]);
    } catch (_) {
      // No local snags for this building yet: nothing to pin.
    }
  }

  // --------------------------------------------------------- feature state

  /// Rebuilds the feature-state texture with core's [FeatureState] (the
  /// encoding `packages/fe_ar`'s shader reads): the target and the
  /// selection highlighted (drawn through walls), progress tints in
  /// Progress mode or colour-by-progress, snags tinted red, and the SHOW
  /// filters (pipes, ducts, equipment, trays) hidden — one upload, no
  /// geometry change.
  ///
  /// **One texture per build, each sent with its `buildId`.** Feature ids are
  /// dense *per build* (CONTRACT C4), so with architecture and MEP on one
  /// floor id 12 names two elements; a single unscoped texture would hide or
  /// tint the other build's namesakes too (switching pipes off would hide
  /// architecture element 12). fieldops-verify, 2026-09-26: this used to
  /// style only the "active" build and send it unscoped.
  Future<void> _pushFeatureState() async {
    final s = _s;
    if (s.features.isEmpty) return;
    final byBuild = <String, List<ArFeature>>{};
    for (final f in s.features) {
      (byBuild[f.buildId] ??= <ArFeature>[]).add(f);
    }
    // Locate's x-ray context: with a target and at most one selection,
    // everything else is ghosted, in every build, so the target stands out.
    // Not while drilling: every service behind the wall should read clearly.
    final ghostOthers = state.mode == ArMode.locate && s.target != null && state.selection.length <= 1 && !state.drilling;
    for (final entry in byBuild.entries) {
      await _pushBuildFeatureState(s, entry.key, entry.value, ghostOthers: ghostOthers);
    }
  }

  Future<void> _pushBuildFeatureState(
    ArSessionState s,
    String buildId,
    List<ArFeature> ofBuild, {
    required bool ghostOthers,
  }) async {
    final tex = featureStateFor(
      buildId: buildId,
      ofBuild: ofBuild,
      ws: state,
      target: s.target,
      ghostOthers: ghostOthers,
      dimAll: s.recheck != null,
      concealed: state.layers.xray ? _concealedFor(s, buildId) : const {},
    );
    await _session.setFeatureState(tex.rgba, tex.width, buildId: buildId);
  }

  /// One build's feature-state texture, pure (tested in
  /// test/ar_workspace_controller_test.dart). Precedence, strongest first:
  /// **hidden** (legend / SHOW filters) → **target** and **selection**
  /// (highlight, sky blue) → **x-ray** (concealed MEP drawn through walls in
  /// its own colour) → **colour-by** (progress palette, snags, system,
  /// discipline) → base (normal, or ghost for Locate's x-ray context).
  ///
  /// [concealed] holds `featureId`s of this build (see [_concealedFor]).
  /// [dimAll] (the fit is drifting, `ArSessionState.recheck`): everything
  /// but the target and selection is ghosted, keeping its tint, so nobody
  /// drills by a model that may have slid; hidden stays hidden.
  static FeatureStateTexture featureStateFor({
    required String buildId,
    required List<ArFeature> ofBuild,
    required ArWorkspaceState ws,
    required ArFeature? target,
    required bool ghostOthers,
    Set<int> concealed = const {},
    bool dimAll = false,
  }) {
    var maxId = 0;
    for (final f in ofBuild) {
      maxId = math.max(maxId, f.featureId);
    }
    final colourBy = ws.mode == ArMode.progress ? ArColourBy.progress : ws.layers.colourBy;
    final l = ws.layers;
    final styles = <int, FeatureStyle>{};
    final hidden = <int>{};
    for (final f in ofBuild) {
      if (_filteredOut(f, l)) hidden.add(f.featureId);
      final slab = _isSheet(f);
      FeatureStyle? style;
      switch (colourBy) {
        case ArColourBy.progress:
          final st = ws.progress.statusOf(f.globalId);
          final rgb = kArProgressRgb[st.wire];
          // Status elements drawn normally in their colour; everything not
          // started (and every slab) is faint slate context, so what has
          // been installed or verified is what the eye lands on.
          style = rgb != null && !slab
              ? FeatureStyle(rgb: rgb)
              : FeatureStyle(display: FeatureDisplay.ghost, rgb: kArNotStartedRgb);
        case ArColourBy.snags:
          if (ws.snagPins.any((p) => p.feature.featureId == f.featureId && p.feature.buildId == f.buildId)) {
            style = const FeatureStyle(rgb: 0xEF4444);
          } else if (slab || ghostOthers) {
            style = FeatureStyle.ghost;
          }
        case ArColourBy.system:
          final key = f.systemGlobalId;
          if (key != null) {
            style = FeatureStyle(display: ghostOthers ? FeatureDisplay.ghost : FeatureDisplay.normal, rgb: (key.hashCode & 0xFFFFFF) | 0x010101);
          } else if (slab || ghostOthers) {
            style = FeatureStyle.ghost;
          }
        case ArColourBy.discipline:
          // Colour MEP by discipline and ghost the slabs. Without a tint the
          // material falls back to one colour per layer (all MEP cyan), which
          // read as "everything looks the same and pale" on the first device
          // run; full-width slabs drawn normally washed out the ceiling.
          final rgb = arDisciplineRgb(f.discipline);
          if (rgb != null || slab) {
            style = FeatureStyle(display: (slab || ghostOthers) ? FeatureDisplay.ghost : FeatureDisplay.normal, rgb: rgb);
          }
      }
      // X-ray: concealed services show through the wall in the colour they
      // already have (or their discipline's), so a hidden cable still reads
      // as "electrical" and a verified pipe as "verified".
      if (concealed.contains(f.featureId) && ArDiscipline.of(f.discipline).isMep) {
        final rgb = (style?.display == FeatureDisplay.ghost ? null : style?.rgb) ?? arDisciplineRgb(f.discipline) ?? ArDiscipline.otherMep.rgb;
        style = FeatureStyle(display: FeatureDisplay.highlight, rgb: rgb);
      }
      if (dimAll) style = FeatureStyle(display: FeatureDisplay.ghost, rgb: style?.rgb);
      if (style != null) styles[f.featureId] = style;
    }
    final selected = ws.selection.where((f) => f.buildId == buildId).map((f) => f.featureId).toSet();
    // Drill check's nearest service is highlighted like a selection, and
    // shown even when the legend hides its discipline: it's the warning.
    final drillHit = ws.drilling ? ws.drill?.feature : null;
    if (drillHit != null && drillHit.buildId == buildId) {
      selected.add(drillHit.featureId);
      hidden.remove(drillHit.featureId);
    }
    for (final id in selected) {
      styles[id] = const FeatureStyle(display: FeatureDisplay.highlight, rgb: kHighlightRgb);
    }
    if (target != null && target.buildId == buildId) {
      styles[target.featureId] = const FeatureStyle(display: FeatureDisplay.highlight, rgb: kHighlightRgb);
    }
    for (final id in hidden) {
      styles[id] = FeatureStyle.hidden;
    }
    return FeatureState.build(
      featureCount: maxId + 1,
      styles: styles,
      base: ghostOthers || dimAll ? FeatureStyle.ghost : FeatureStyle.normal,
    );
  }

  List<ArFeature>? _concealedOf;
  ArPlan? _concealedPlan;
  double? _concealedDatum;
  Map<String, Set<int>> _concealedByBuild = const {};

  /// This build's feature ids of MEP the element card would call concealed
  /// (in a wall, the floor, a slab or above the ceiling). Cached per feature
  /// list, plan and datum: placing every service against every wall is the
  /// one costly step, and it only changes with a new floor.
  Set<int> _concealedFor(ArSessionState s, String buildId) {
    final datum = _datumOf(s);
    if (!identical(s.features, _concealedOf) || !identical(s.plan, _concealedPlan) || datum != _concealedDatum) {
      _concealedOf = s.features;
      _concealedPlan = s.plan;
      _concealedDatum = datum;
      final walls = _wallsFor(s.plan);
      final slabs = _slabsFor(s.features);
      final byBuild = <String, Set<int>>{};
      for (final f in s.features) {
        if (!ArDiscipline.of(f.discipline).isMep) continue;
        final p = _drill.place(bboxMin: f.bboxMin, bboxMax: f.bboxMax, floorY: datum, walls: walls, slabs: slabs);
        if (p.zone != ServiceZone.room) (byBuild[f.buildId] ??= <int>{}).add(f.featureId);
      }
      _concealedByBuild = byBuild;
    }
    return _concealedByBuild[buildId] ?? const {};
  }

  /// Slabs, roofs and coverings: surfaces as big as the room. Drawn solid
  /// over a camera image they hide the real ceiling and floor.
  static bool _isSheet(ArFeature f) {
    final t = f.ifcType.toUpperCase();
    return t.contains('SLAB') || t.contains('ROOF') || t.contains('COVERING') || t.contains('FOOTING');
  }

  /// Public for Demo mode's painted scene, which has no feature texture.
  static bool filteredOut(ArFeature f, ArLayerState l) => _filteredOut(f, l);

  /// Every observation behind the fit is a floor-tap corner (`CornerObs`
  /// method `floorTap`): no wall face was detected, so position and heading
  /// rest on where the user tapped the floor. Usable, but rough, and the
  /// badge alone ("Placed") doesn't say so: the workspace shows a hint.
  static bool roughPlacement(ArSessionState s) =>
      s.isPlaced && s.observations.isNotEmpty && s.observations.every((o) => o is CornerObs && o.roughHeading);

  /// The legend's discipline filters and the Layers panel's SHOW switches,
  /// per element. The SHOW switches are MEP switches: architecture and
  /// structure never match them — otherwise "Equipment off" would hide every
  /// wall now that each build gets its own texture. Walls and structure
  /// follow their own chips (= the model switches) per element as well,
  /// because an architecture IFC often carries the columns and slabs, and
  /// the Structure chip must hide those too. Disciplines are the server's
  /// (`services/ar/geometry/classify.ts`).
  static bool _filteredOut(ArFeature f, ArLayerState l) {
    final disc = ArDiscipline.of(f.discipline);
    if (disc == ArDiscipline.walls) return !l.architecture;
    if (disc == ArDiscipline.structure) return !l.structure;
    if (l.hiddenDisciplines.contains(disc.name)) return true;
    final t = f.ifcType.toLowerCase();
    if (!l.pipes && (t.contains('pipe') || t.contains('valve'))) return true;
    if (!l.ducts && t.contains('duct')) return true;
    if (!l.cableTrays && t.contains('cable')) return true;
    if (!l.equipment && !f.isRun && !f.isValve) return true;
    return false;
  }
}

/// The legend's chips: six MEP disciplines (the [arDisciplineRgb] colours)
/// plus Structure and Walls, which keep their layer look.
enum ArDiscipline {
  electrical,
  plumbing,
  hvac,
  fire,
  controls,
  otherMep,
  structure,
  walls;

  static const mepValues = [electrical, plumbing, hvac, fire, controls, otherMep];

  /// The same prefixes as [arDisciplineRgb]; anything unrecognised is
  /// "other MEP" (cyan), which is what the renderer draws it as.
  static ArDiscipline of(String discipline) {
    final d = discipline.toLowerCase();
    if (d.startsWith('architect')) return walls;
    if (d.startsWith('struct')) return structure;
    if (d.startsWith('elec')) return electrical;
    if (d.startsWith('plumb')) return plumbing;
    if (d.startsWith('hvac') || d.startsWith('mech')) return hvac;
    if (d.startsWith('fire')) return fire;
    if (d.startsWith('control')) return controls;
    return otherMep;
  }

  bool get isMep => this != structure && this != walls;

  /// The tint the model is drawn with; null for Structure and Walls.
  int? get rgb => switch (this) {
    electrical => arDisciplineRgb('electrical'),
    plumbing => arDisciplineRgb('plumbing'),
    hvac => arDisciplineRgb('hvac'),
    fire => arDisciplineRgb('fire'),
    controls => arDisciplineRgb('controls'),
    otherMep => arDisciplineRgb('mep'),
    structure || walls => null,
  };
}

/// AR discipline colours (sRGB), chosen to read against a camera image and
/// to match the web plan's legend. Null for architecture and structure, which
/// keep their layer look (edges, faint slate).
int? arDisciplineRgb(String discipline) {
  final d = discipline.toLowerCase();
  if (d.startsWith('elec')) return 0xF59E0B; // amber
  if (d.startsWith('plumb')) return 0x10B981; // green
  if (d.startsWith('hvac') || d.startsWith('mech')) return 0x3B82F6; // blue
  if (d.startsWith('fire')) return 0xEF4444; // red
  if (d.startsWith('control')) return 0xA855F7; // purple
  if (d == 'mep') return 0x06B6D4; // cyan
  return null;
}

final arWorkspaceProvider = NotifierProvider.autoDispose<ArWorkspaceController, ArWorkspaceState>(
  ArWorkspaceController.new,
);
