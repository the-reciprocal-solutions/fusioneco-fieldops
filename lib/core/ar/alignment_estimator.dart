import 'dart:math' as math;

import 'vec.dart';

/// Per-observation position uncertainty in metres (CONTRACT C2). Tuned in
/// slice 0 (AR-4); change here and in the server's coverage module together.
abstract final class ArSigma {
  static const surveyed = 0.005;
  static const feature = 0.02;
  static const derived = 0.03;

  static const cornerLidar = 0.02;
  static const cornerPlanes = 0.04;
  static const cornerFloorTap = 0.06;

  /// Two walls fitted from 3–5 Raw Depth taps each (`wall_fit.dart`): better
  /// than a floor tap's one borrowed wall, worse than tracked planes.
  static const cornerDepthTaps = 0.05;

  /// σ grows by this much per metre walked since the observation: tracking
  /// drift is proportional to distance, so an old observation from across
  /// the building counts for less than the board you just scanned.
  static const driftPerMetre = 0.02;

  static double forMarkerClass(String accuracyClass) => switch (accuracyClass) {
        'surveyed' => surveyed,
        'feature' => feature,
        _ => derived,
      };

  /// A marker observed by PnP (the last-resort method, orientation from the
  /// four QR corners) counts double: its centre sits on no measured surface.
  /// A board locked on its AprilTags (16 corners, median of 20–30 frames)
  /// counts 0.7×, never better than a surveyed board's own position.
  static double forMarker(String accuracyClass, String method) {
    final base = forMarkerClass(accuracyClass);
    return switch (method) {
      'pnp' => base * 2,
      'tag' => math.max(surveyed, base * 0.7),
      _ => base,
    };
  }

  /// An unknown method is treated as the weakest (floor tap), never the best.
  static double forCorner(String method) => switch (method.toLowerCase()) {
        'lidar' || 'depth' => cornerLidar,
        'plane' || 'planes' => cornerPlanes,
        'depthtaps' => cornerDepthTaps,
        _ => cornerFloorTap,
      };
}

/// One thing seen in the AR world that is also known in the model: a board
/// (its registered centre) or a snapped corner (where the corner line meets
/// the floor). The estimator treats both the same way; only the one-shot
/// heading differs (CONTRACT C2).
sealed class ArObservation {
  const ArObservation({
    required this.id,
    required this.aAr,
    required this.bTile,
    required this.sigmaM,
    this.distanceSinceM = 0,
  });

  /// Marker code or corner candidate id — the `ref` in the alignment event.
  final String id;

  /// Observed position in the AR world (device frame, Y-up by gravity).
  final Vec3 aAr;

  /// The same point in the tile frame (model).
  final Vec3 bTile;

  /// Position σ in metres ([ArSigma]).
  final double sigmaM;

  /// How far the device has walked since this was observed.
  final double distanceSinceM;

  /// `marker` or `corner`, as the alignment event records it.
  String get kind;

  /// The same observation after the tracker refined its native anchor.
  ArObservation withAr(Vec3 aAr);

  /// The same observation, older by [distanceSinceM] of walking.
  ArObservation withDistanceSince(double distanceSinceM);
}

final class MarkerObs extends ArObservation {
  const MarkerObs({
    required super.id,
    required super.aAr,
    required super.bTile,
    required super.sigmaM,
    super.distanceSinceM = 0,
    required this.normalAr,
    required this.normalTile,
    this.method = 'plane',
  });

  final Vec3 normalAr;
  final Vec3 normalTile;

  /// `lidar | plane | depth | pnp`.
  final String method;

  @override
  String get kind => 'marker';

  @override
  MarkerObs withAr(Vec3 aAr) => MarkerObs(
        id: id,
        aAr: aAr,
        bTile: bTile,
        sigmaM: sigmaM,
        distanceSinceM: distanceSinceM,
        normalAr: normalAr,
        normalTile: normalTile,
        method: method,
      );

  @override
  MarkerObs withDistanceSince(double distanceSinceM) => MarkerObs(
        id: id,
        aAr: aAr,
        bTile: bTile,
        sigmaM: sigmaM,
        distanceSinceM: distanceSinceM,
        normalAr: normalAr,
        normalTile: normalTile,
        method: method,
      );
}

/// A snapped corner. [faceAAr]/[faceBAr] are the detected face directions
/// (horizontal, `[nx, nz]`) already **paired** with the candidate's
/// [faceATile]/[faceBTile] — `CornerMatcher` does the pairing, using the side
/// the camera is on. That pairing is what makes one corner a full 4-DoF
/// placement (position *and* heading).
final class CornerObs extends ArObservation {
  const CornerObs({
    required super.id,
    required super.aAr,
    required super.bTile,
    required super.sigmaM,
    super.distanceSinceM = 0,
    required this.faceAAr,
    required this.faceBAr,
    required this.faceATile,
    required this.faceBTile,
    this.method = 'planes',
    this.baselineM,
  });

  final Vec2 faceAAr;
  final Vec2 faceBAr;
  final Vec2 faceATile;
  final Vec2 faceBTile;

  /// `lidar | planes | floorTap | depthTaps`.
  final String method;

  /// Set when the faces were turned to a long-baseline heading
  /// (`BaselineHeading`): the corner → far-point distance it came from. The
  /// faces are then far better than [method] says, and no longer "rough".
  final double? baselineM;

  /// The heading comes from a short look at the walls (a borrowed plane or a
  /// few taps), not from tracked planes, LiDAR or a long baseline.
  bool get roughHeading => baselineM == null && (method == 'floorTap' || method == WallFitMethod.depthTaps);

  @override
  String get kind => 'corner';

  @override
  CornerObs withAr(Vec3 aAr) => CornerObs(
        id: id,
        aAr: aAr,
        bTile: bTile,
        sigmaM: sigmaM,
        distanceSinceM: distanceSinceM,
        faceAAr: faceAAr,
        faceBAr: faceBAr,
        faceATile: faceATile,
        faceBTile: faceBTile,
        method: method,
        baselineM: baselineM,
      );

  @override
  CornerObs withDistanceSince(double distanceSinceM) => CornerObs(
        id: id,
        aAr: aAr,
        bTile: bTile,
        sigmaM: sigmaM,
        distanceSinceM: distanceSinceM,
        faceAAr: faceAAr,
        faceBAr: faceBAr,
        faceATile: faceATile,
        faceBTile: faceBTile,
        method: method,
        baselineM: baselineM,
      );
}

/// The wall-taps corner method (`wall_fit.dart`), here so the estimator does
/// not depend on the fitter.
abstract final class WallFitMethod {
  static const depthTaps = 'depthTaps';
}

/// The badge states (docs/ar-setup-and-gamma-parity.md §2.7).
enum AlignmentQuality {
  /// Nothing observed: "Snap a corner or scan a board".
  none,

  /// Amber: one observation, or several too close together to fix heading
  /// from positions. Sharp near the observation.
  placed,

  /// Green: two or more observations at least 1.5 m apart that agree within
  /// 5 cm. The only state that may be shown as green.
  locked,

  /// Amber "re-snap": the runtime edge check failed. Never set by [AlignmentEstimator.fit];
  /// the session applies it with [AlignmentFit.withQuality].
  drifting,

  /// Grey "nudged": moved by hand. Never shown as green, whatever the residuals.
  manual,

  /// Red: observations disagree by more than 5 cm even after dropping
  /// outliers. The site may differ from the model here.
  siteMismatch,
}

/// The result of one fit. `arFromTile` is what goes to
/// `ArEngine.setModelTransform`.
class AlignmentFit {
  AlignmentFit({
    required this.yawRad,
    required this.t,
    required this.arFromTile,
    required this.maxResidualM,
    required this.residualsM,
    required this.outliers,
    required this.spreadM,
    required this.quality,
    required this.observationCount,
    this.method = 'none',
    this.nudgeM = 0,
    this.verticalErrorsM = const {},
    this.floorAnchored = false,
    this.scale = 1,
    this.stretchX = 1,
    this.stretchZ = 1,
  });

  factory AlignmentFit.none() => AlignmentFit(
        yawRad: 0,
        t: Vec3.zero,
        arFromTile: Mat4.identity(),
        maxResidualM: 0,
        residualsM: const {},
        outliers: const [],
        spreadM: 0,
        quality: AlignmentQuality.none,
        observationCount: 0,
      );

  final double yawRad;
  final Vec3 t;
  final Mat4 arFromTile;

  /// Largest residual among the observations the fit kept (outliers
  /// excluded). This is the *measured* quality the badge shows.
  final double maxResidualM;

  /// Residual of **every** observation passed in, outliers included (their
  /// residual is what the marker-health rules read), keyed by id.
  final Map<String, double> residualsM;

  /// Ids dropped as outliers (only ever with 3 or more observations).
  final List<String> outliers;

  /// Weighted RMS horizontal distance of the kept observations from their
  /// centroid, in the model. Below 1.5 m positions can't fix the heading.
  final double spreadM;

  final AlignmentQuality quality;

  /// Observations the fit kept (inliers).
  final int observationCount;

  /// How the heading was found: `positions`, `directions` (one observation,
  /// or several close together), or `none`. Recorded as the alignment
  /// event's `method` / `arContext.fitMethod`.
  final String method;

  /// Size of the hand nudge folded into [t], in metres (0 when none).
  final double nudgeM;

  /// Per observation, how far above (+) or below (−) its model height it was
  /// seen, in metres. With [floorAnchored] this is the board's hanging error
  /// (or the floor finish), and it is excluded from [residualsM].
  final Map<String, double> verticalErrorsM;

  /// The height came from the tracked floor, not from the observations.
  final bool floorAnchored;

  /// "Place by hand" only (`manual_place_math.dart`): the uniform size the
  /// user pinched to, and the optional per-axis "Stretch to fit" factors on
  /// top of it (model X and Z). 1 everywhere else: a measured fit is always
  /// true size. [arFromTile] already contains them.
  final double scale;
  final double stretchX;
  final double stretchZ;

  /// False when the model is drawn bigger or smaller than it really is:
  /// anything measured against it is approximate ("Not true size").
  bool get isTrueSize =>
      (scale - 1).abs() < 0.005 && (stretchX - 1).abs() < 0.005 && (stretchZ - 1).abs() < 0.005;

  /// Placed by hand (`method == 'manual'`), not measured from corners or boards.
  bool get isHandPlaced => method == 'manual';

  double get yawDeg => radToDeg(yawRad);
  double get maxResidualMm => maxResidualM * 1000;

  bool get isPlaced => quality != AlignmentQuality.none;

  /// Model point → AR world.
  Vec3 tileToAr(Vec3 p) => arFromTile.transformPoint(p);

  /// AR world point → model. Used to save a board at the pose the fit gives
  /// it ("leave a board") and to place pins the user taps.
  /// A hand placement at a non-100 % size is not rigid, so this takes the
  /// general inverse then ([Mat4.inverse]); every other fit stays on the
  /// exact rigid one.
  Vec3 arToTile(Vec3 p) => arFromTile.inverse().transformPoint(p);

  Vec3 dirTileToAr(Vec3 d) => arFromTile.transformDir(d);
  Vec3 dirArToTile(Vec3 d) => arFromTile.inverse().transformDir(d);

  /// The runtime drift check marks a fit [AlignmentQuality.drifting] without
  /// refitting; the next observation's refit clears it.
  AlignmentFit withQuality(AlignmentQuality quality) => AlignmentFit(
        yawRad: yawRad,
        t: t,
        arFromTile: arFromTile,
        maxResidualM: maxResidualM,
        residualsM: residualsM,
        outliers: outliers,
        spreadM: spreadM,
        quality: quality,
        observationCount: observationCount,
        method: method,
        nudgeM: nudgeM,
        verticalErrorsM: verticalErrorsM,
        floorAnchored: floorAnchored,
        scale: scale,
        stretchX: stretchX,
        stretchZ: stretchZ,
      );

  @override
  String toString() => 'AlignmentFit(${quality.name}, yaw ${yawDeg.toStringAsFixed(2)}°, '
      't $t, max ${maxResidualMm.toStringAsFixed(1)} mm, n $observationCount, '
      'spread ${spreadM.toStringAsFixed(2)} m, method $method${floorAnchored ? ', floor' : ''}, outliers $outliers)';
}

/// Closed-form weighted 4-DoF fit: yaw about +Y plus translation
/// (docs/ar-bim-overlay.md §4.3, CONTRACT C2). No iteration, stable for any
/// number of observations, and pure — every decision about where the model
/// goes is made here, in Dart, and unit-tested; native code only measures.
///
/// ```
/// wᵢ = 1 / (σᵢ² + (0.02 · distanceSinceᵢ)²)
/// θ  = atan2(Σ wᵢ (ãx·b̃z − ãz·b̃x), Σ wᵢ (ãx·b̃x + ãz·b̃z))
/// t  = ā − R(θ)·b̄
/// ```
///
/// With one observation, or a spread under 1.5 m, positions carry no heading
/// information, so the heading comes from measured directions instead: a
/// board's wall normal, or a corner's two faces.
class AlignmentEstimator {
  const AlignmentEstimator();

  /// Heading switches from directions to positions at this spread.
  static const spreadForPositionsM = 1.5;

  /// When every direction is rough ([CornerObs.roughHeading]: floor taps and
  /// wall taps, no boards), positions win from this spread (two corners 2 m
  /// apart): 5 cm at each end over 2 m is about 2°, a floor tap's borrowed
  /// wall often worse. The badge still needs [spreadForPositionsM] for green.
  static const spreadForRoughPositionsM = 1.0;

  /// A long-baseline corner's faces count this much more than an ordinary
  /// observation's directions when several are averaged.
  static const baselineDirectionWeight = 4.0;

  /// Green needs every kept residual at or under this; red above it.
  static const lockResidualM = 0.05;

  /// Worst residual still shown green; between this and [lockResidualM] the
  /// fit is usable but amber (docs/ar-setup-and-gamma-parity.md, P-012).
  static const greenResidualM = 0.02;

  /// An observation is an outlier when its residual exceeds
  /// `max(outlierSigmas · σ, outlierFloorM)`.
  static const outlierSigmas = 3.0;
  static const outlierFloorM = 0.05;

  /// A direction shorter than this once projected on the floor (a
  /// floor-mounted board's normal points up) carries no heading.
  static const _minHorizontalDir = 0.2;

  static double weightOf(ArObservation o) {
    final drift = ArSigma.driftPerMetre * o.distanceSinceM;
    return 1 / (o.sigmaM * o.sigmaM + drift * drift);
  }

  /// Fits [obs]. With [manual] (the user nudged the model) the quality is
  /// [AlignmentQuality.manual] whatever the residuals, because a hand
  /// adjustment is never evidence. [nudgeAr] is the hand nudge in the AR
  /// world, folded into the translation (and implies [manual]).
  ///
  /// Outliers: only with 3 or more observations — with exactly two that
  /// disagree nobody can tell which one is wrong, so the result is
  /// [AlignmentQuality.siteMismatch] and the UI asks for a third. The worst
  /// offender (largest residual relative to its own tolerance) is dropped
  /// and the fit rerun, one at a time, so a single bad board can't drag a
  /// good one out with it.
  /// [floorAr] (the tracked floor's AR-world Y) with [floorTileY] (the
  /// model's finished floor in the tile frame) fixes the vertical: the model
  /// floor sits on the real floor, and observations only set yaw and the
  /// horizontal position. Residuals are then horizontal, and each
  /// observation's height error is reported in [AlignmentFit.verticalErrorsM].
  AlignmentFit fit(
    List<ArObservation> obs, {
    bool manual = false,
    Vec3? nudgeAr,
    double? floorAr,
    double? floorTileY,
  }) {
    if (obs.isEmpty) {
      return manual ? AlignmentFit.none().withQuality(AlignmentQuality.manual) : AlignmentFit.none();
    }

    final inliers = List<ArObservation>.of(obs);
    final outliers = <String>[];
    var solution = _solve(inliers);

    while (inliers.length >= 3) {
      ArObservation? worst;
      var worstRatio = 1.0;
      for (final o in inliers) {
        final tolerance = math.max(outlierSigmas * o.sigmaM, outlierFloorM);
        final ratio = solution.residual(o) / tolerance;
        if (ratio > worstRatio) {
          worst = o;
          worstRatio = ratio;
        }
      }
      if (worst == null) break;
      inliers.remove(worst);
      outliers.add(worst.id);
      solution = _solve(inliers);
    }

    final nudge = nudgeAr ?? Vec3.zero;
    final isManual = manual || nudgeAr != null;
    final onFloor = floorAr != null && floorTileY != null;
    var t = solution.t + nudge;
    // Yaw-only rotation leaves Y alone, so aY = bY + tY: the floor gives tY.
    if (onFloor) t = Vec3(t.x, floorAr - floorTileY, t.z);
    final transform = Mat4.fromYawTranslation(solution.yaw, t);

    final residuals = <String, double>{};
    final vertical = <String, double>{};
    for (final o in obs) {
      final d = transform.transformPoint(o.bTile) - o.aAr;
      residuals[o.id] = onFloor ? Vec3(d.x, 0, d.z).length : d.length;
      vertical[o.id] = -d.y;
    }
    var maxResidual = 0.0;
    for (final o in inliers) {
      maxResidual = math.max(maxResidual, residuals[o.id]!);
    }

    final n = inliers.length;
    final AlignmentQuality quality;
    if (isManual) {
      quality = AlignmentQuality.manual;
    } else if (n >= 2 && maxResidual > lockResidualM) {
      // Checked before "placed" on purpose: two observations that disagree
      // must never read as a calm amber, even when they are close together.
      quality = AlignmentQuality.siteMismatch;
    } else if (n == 1 || solution.spread < spreadForPositionsM || maxResidual > greenResidualM) {
      // Green needs two references far enough apart to fix yaw from their
      // positions, agreeing within 2 cm; anything less stays amber, where the
      // UI asks for another board or corner.
      quality = AlignmentQuality.placed;
    } else {
      quality = AlignmentQuality.locked;
    }

    return AlignmentFit(
      yawRad: solution.yaw,
      t: t,
      arFromTile: transform,
      maxResidualM: maxResidual,
      residualsM: Map.unmodifiable(residuals),
      outliers: List.unmodifiable(outliers),
      spreadM: solution.spread,
      verticalErrorsM: Map.unmodifiable(vertical),
      floorAnchored: onFloor,
      quality: quality,
      observationCount: n,
      method: solution.method,
      nudgeM: nudge.length,
    );
  }

  _Solution _solve(List<ArObservation> obs) {
    final weights = [for (final o in obs) weightOf(o)];
    var wSum = 0.0;
    var aSum = Vec3.zero;
    var bSum = Vec3.zero;
    for (var i = 0; i < obs.length; i++) {
      wSum += weights[i];
      aSum += obs[i].aAr * weights[i];
      bSum += obs[i].bTile * weights[i];
    }
    final aBar = aSum * (1 / wSum);
    final bBar = bSum * (1 / wSum);

    var spread2 = 0.0;
    for (var i = 0; i < obs.length; i++) {
      final d = obs[i].bTile.distanceXzTo(bBar);
      spread2 += weights[i] * d * d;
    }
    final spread = math.sqrt(spread2 / wSum);

    double yaw;
    String method;
    final roughDirections = obs.every((o) => o is CornerObs && o.roughHeading);
    if (obs.length >= 2 && (spread >= spreadForPositionsM || (roughDirections && spread >= spreadForRoughPositionsM))) {
      yaw = _yawFromPositions(obs, weights, aBar, bBar);
      method = 'positions';
    } else {
      final fromDirections = _yawFromDirections(obs, weights);
      if (fromDirections != null) {
        yaw = fromDirections;
        method = 'directions';
      } else if (obs.length >= 2) {
        // No usable direction (floor boards only): positions are weak at
        // this spread but still better than nothing.
        yaw = _yawFromPositions(obs, weights, aBar, bBar);
        method = 'positions';
      } else {
        yaw = 0;
        method = 'none';
      }
    }

    final t = aBar - _rotate(bBar, yaw);
    return _Solution(yaw: yaw, t: t, spread: spread, method: method);
  }

  static double _yawFromPositions(
    List<ArObservation> obs,
    List<double> weights,
    Vec3 aBar,
    Vec3 bBar,
  ) {
    var sinSum = 0.0;
    var cosSum = 0.0;
    for (var i = 0; i < obs.length; i++) {
      final a = obs[i].aAr - aBar;
      final b = obs[i].bTile - bBar;
      sinSum += weights[i] * (a.x * b.z - a.z * b.x);
      cosSum += weights[i] * (a.x * b.x + a.z * b.z);
    }
    return math.atan2(sinSum, cosSum);
  }

  /// Weighted circular mean of each observation's heading difference. A
  /// marker contributes the angle from its registered wall normal to the
  /// observed one; a corner the mean of its two faces' angles.
  static double? _yawFromDirections(List<ArObservation> obs, List<double> weights) {
    var s = 0.0;
    var c = 0.0;
    var any = false;

    void add(Vec2 tile, Vec2 ar, double w) {
      if (tile.length < _minHorizontalDir || ar.length < _minHorizontalDir) return;
      final theta = headingOf(ar) - headingOf(tile);
      s += w * math.sin(theta);
      c += w * math.cos(theta);
      any = true;
    }

    for (var i = 0; i < obs.length; i++) {
      final w = weights[i];
      switch (obs[i]) {
        case MarkerObs(:final normalTile, :final normalAr):
          add(normalTile.xz, normalAr.xz, w);
        case CornerObs(:final faceATile, :final faceAAr, :final faceBTile, :final faceBAr, :final baselineM):
          final cw = baselineM == null ? w / 2 : w * baselineDirectionWeight / 2;
          add(faceATile, faceAAr, cw);
          add(faceBTile, faceBAr, cw);
      }
    }
    if (!any || (s.abs() < 1e-12 && c.abs() < 1e-12)) return null;
    return math.atan2(s, c);
  }

  static Vec3 _rotate(Vec3 p, double yaw) {
    final c = math.cos(yaw);
    final s = math.sin(yaw);
    return Vec3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c);
  }

  /// The guided single-axis nudge (docs/ar-setup-and-gamma-parity.md §2.6):
  /// facing along a wall, one slider moves the model only perpendicular to
  /// that wall. Returns the horizontal AR-world unit direction the slider
  /// moves along — the normal of the wall the camera looks most nearly
  /// *along* — or null with no walls. There is never a vertical axis: the
  /// floor sets height.
  static Vec3? nudgeAxis({
    required Vec3 cameraForwardAr,
    required List<Vec2> wallNormalsAr,
  }) {
    final forward = cameraForwardAr.xz.normalized;
    Vec2? best;
    var bestAlong = double.infinity;
    for (final raw in wallNormalsAr) {
      final n = raw.normalized;
      if (n.length == 0) continue;
      // |cos| of the angle between view and normal: 0 = looking along the wall.
      final along = forward.length == 0 ? 0.0 : forward.dot(n).abs();
      if (along < bestAlong) {
        bestAlong = along;
        best = n;
      }
    }
    return best == null ? null : Vec3(best.x, 0, best.y);
  }
}

class _Solution {
  const _Solution({
    required this.yaw,
    required this.t,
    required this.spread,
    required this.method,
  });

  final double yaw;
  final Vec3 t;
  final double spread;
  final String method;

  double residual(ArObservation o) {
    final c = math.cos(yaw);
    final s = math.sin(yaw);
    final b = o.bTile;
    final predicted = Vec3(b.x * c + b.z * s + t.x, b.y + t.y, -b.x * s + b.z * c + t.z);
    return (predicted - o.aAr).length;
  }
}

/// The runtime drift check (docs/ar-setup-and-gamma-parity.md §2.6): the
/// native side compares modelled structural edges with measured planes and
/// reports an offset; a **consistent** offset over 3 cm lasting 2 s means the
/// overlay has drifted. One spike (someone walks past the wall) never trips it.
class DriftMonitor {
  DriftMonitor({
    this.thresholdM = 0.03,
    this.holdFor = const Duration(seconds: 2),
  });

  final double thresholdM;
  final Duration holdFor;
  DateTime? _since;

  /// Feeds one measured offset. True once it has stayed above the threshold
  /// for [holdFor]; any sample at or under the threshold starts over.
  bool add(DateTime at, double offsetM) {
    if (offsetM <= thresholdM) {
      _since = null;
      return false;
    }
    final since = _since ??= at;
    return at.difference(since) >= holdFor;
  }

  void reset() => _since = null;
}
