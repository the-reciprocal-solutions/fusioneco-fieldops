import 'dart:math' as math;

import 'alignment_estimator.dart' show WallFitMethod;
import 'corner_matcher.dart' show DetectedCorner;
import 'vec.dart';

/// A corner from wall taps (method `depthTaps`): the fallback for plain
/// painted rooms, where ARCore tracks no vertical planes and a corner snap
/// otherwise falls back to `floorTap` (floor point + the heading of whatever
/// vertical surface happens to be near — LEARNINGS "fe_ar on a real room" #6).
///
/// The user taps each of the two walls near the corner 3–5 times; every tap
/// is one `ArEngine.depthPointAt` measurement (ARCore Raw Depth where the
/// confidence is high). Each wall is fitted as a vertical plane — a line on
/// the floor plane, total least squares on XZ with leave-one-out outlier
/// rejection — and the two lines are intersected on the tracked floor. The
/// result is an ordinary [DetectedCorner], so `CornerMatcher` pairs its faces
/// exactly as it does a native snap. Pure and unit-tested
/// (`test/ar_wall_fit_test.dart`); native code only measures points.
class WallTap {
  const WallTap(this.posAr, [this.normalAr]);

  /// The measured point in the AR world (Y up).
  final Vec3 posAr;

  /// The surface normal the engine estimated around it, when it had one.
  final Vec3? normalAr;
}

/// One wall as a vertical plane: a line on the floor, `(x, z)`.
class WallLine {
  const WallLine({
    required this.point,
    required this.normal,
    required this.rmsM,
    required this.spanM,
    required this.inliers,
    this.outliers = const [],
    this.fromNormals = false,
  });

  /// A point on the line (the inliers' centroid).
  final Vec2 point;

  /// Unit horizontal normal, facing the camera when one was given.
  final Vec2 normal;

  /// RMS distance of the kept taps from the line.
  final double rmsM;

  /// How far the kept taps spread along the wall.
  final double spanM;

  /// Taps kept.
  final int inliers;

  /// Indices (into the list passed to [WallFitter.fit]) dropped as outliers.
  final List<int> outliers;

  /// The taps were too close together to give a direction, so it came from
  /// the engine's per-tap normals instead (weaker; see [WallFitter.minSpanM]).
  final bool fromNormals;

  /// Along the wall.
  Vec2 get direction => Vec2(-normal.y, normal.x);

  /// Signed distance of [p] from the line, positive on the normal's side.
  double signedDistance(Vec2 p) => (p - point).dot(normal);
}

/// Why a wall or corner fit was refused; the setup card words it.
enum WallFitFailure {
  /// Fewer than [WallFitter.minTaps] usable taps on a wall.
  tooFewTaps,

  /// The taps sit on one spot and carry no usable normal.
  noDirection,

  /// The two walls are within 30° of parallel: no corner between them.
  parallel,

  /// The corner lands implausibly far from the taps (two different walls
  /// of the room, or a tap on furniture that survived the outlier check).
  tooFar,
}

/// The two fitted walls and the corner where they meet the floor.
class WallCorner {
  const WallCorner({
    required this.posAr,
    required this.faceAAr,
    required this.faceBAr,
    required this.angleDeg,
    required this.kind,
    required this.wallA,
    required this.wallB,
  });

  /// Where the corner line meets the tracked floor.
  final Vec3 posAr;

  /// Horizontal face normals, facing the camera, ordered so
  /// `a.x*b.z - a.z*b.x >= 0` (the native detector's convention).
  final Vec2 faceAAr;
  final Vec2 faceBAr;
  final double angleDeg;

  /// `inside | outside`.
  final String kind;
  final WallLine wallA;
  final WallLine wallB;

  /// The worse of the two walls' RMS: a quality hint for the card.
  double get rmsM => math.max(wallA.rmsM, wallB.rmsM);

  DetectedCorner toDetected() => DetectedCorner(
        posAr: posAr,
        faceAAr: faceAAr,
        faceBAr: faceBAr,
        angleDeg: angleDeg,
        kind: kind,
        method: WallFitter.method,
      );
}

/// A fit that either worked ([value]) or says why not ([failure]).
class WallFitResult<T> {
  const WallFitResult.ok(T this.value) : failure = null;
  const WallFitResult.failed(WallFitFailure this.failure) : value = null;

  final T? value;
  final WallFitFailure? failure;

  bool get ok => value != null;
}

class WallFitter {
  const WallFitter();

  /// The observation method this produces (`ArSigma.cornerDepthTaps`).
  static const method = WallFitMethod.depthTaps;

  static const minTaps = 3;

  /// Taps per wall the setup card asks for at most; the fit takes any number.
  static const maxTaps = 5;

  /// A tap further than this from the line through the others is an outlier
  /// (a door frame, a skirting board, a picture). Raw Depth on a flat wall is
  /// good to 1–2 cm at 1–2 m.
  static const outlierFloorM = 0.03;
  static const outlierSigmas = 3.0;

  /// Below this spread along the wall the taps' own geometry can't give a
  /// direction; the engine's per-tap normals are used if there are any.
  static const minSpanM = 0.15;

  /// Two walls must meet at 30° or more (a real corner is 60–150°).
  static const minWallAngleDeg = 30.0;

  /// The corner must lie within this of the taps on each wall.
  static const maxReachM = 2.5;

  /// A tap whose normal points more up than sideways is the floor (or a
  /// table), not a wall.
  static bool looksLikeFloor(Vec3? normalAr) => normalAr != null && normalAr.normalized.y.abs() > 0.7;

  /// Fits one wall. [cameraAr] orients the normal toward the camera.
  WallFitResult<WallLine> fit(List<WallTap> taps, {Vec3? cameraAr}) {
    if (taps.length < minTaps) return const WallFitResult.failed(WallFitFailure.tooFewTaps);
    final kept = List<int>.generate(taps.length, (i) => i);
    final dropped = <int>[];

    // Leave-one-out: with 3–5 taps a single bad one drags an ordinary fit
    // toward itself, so each tap is judged against the line through the
    // others. Never below minTaps (two points always make a perfect line).
    while (kept.length > minTaps) {
      int? worst;
      var worstExcess = 0.0;
      for (final i in kept) {
        final others = [for (final j in kept) if (j != i) taps[j].posAr.xz];
        final line = _tls(others);
        if (line == null) continue;
        final d = (taps[i].posAr.xz - line.$1).dot(line.$2).abs();
        final rms = _rms(others, line);
        final tolerance = math.max(outlierFloorM, outlierSigmas * rms);
        final excess = d / tolerance;
        if (excess > 1 && excess > worstExcess) {
          worst = i;
          worstExcess = excess;
        }
      }
      if (worst == null) break;
      kept.remove(worst);
      dropped.add(worst);
    }

    final pts = [for (final i in kept) taps[i].posAr.xz];
    final line = _tls(pts);
    if (line == null) return const WallFitResult.failed(WallFitFailure.noDirection);
    var (centroid, normal) = line;
    final dir = Vec2(-normal.y, normal.x);
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final p in pts) {
      final s = (p - centroid).dot(dir);
      lo = math.min(lo, s);
      hi = math.max(hi, s);
    }
    final span = hi - lo;

    var fromNormals = false;
    if (span < minSpanM) {
      // Clustered taps: their scatter is depth noise, not the wall's line.
      final n = _meanNormal([for (final i in kept) taps[i].normalAr], cameraAr, centroid);
      if (n == null) return const WallFitResult.failed(WallFitFailure.noDirection);
      normal = n;
      fromNormals = true;
    }
    if (cameraAr != null && (cameraAr.xz - centroid).dot(normal) < 0) normal = -normal;
    return WallFitResult.ok(WallLine(
      point: centroid,
      normal: normal,
      rmsM: _rms(pts, (centroid, normal)),
      spanM: span,
      inliers: kept.length,
      outliers: List.unmodifiable(dropped),
      fromNormals: fromNormals,
    ));
  }

  /// Both walls, then the corner on the floor at [floorY].
  WallFitResult<WallCorner> corner(
    List<WallTap> tapsA,
    List<WallTap> tapsB, {
    required double floorY,
    required Vec3 cameraAr,
  }) {
    final a = fit(tapsA, cameraAr: cameraAr);
    if (!a.ok) return WallFitResult.failed(a.failure!);
    final b = fit(tapsB, cameraAr: cameraAr);
    if (!b.ok) return WallFitResult.failed(b.failure!);
    final wa = a.value!;
    final wb = b.value!;

    final det = wa.normal.cross(wb.normal);
    if (det.abs() < math.sin(minWallAngleDeg * math.pi / 180)) {
      return const WallFitResult.failed(WallFitFailure.parallel);
    }
    // n_a · x = n_a · p_a and n_b · x = n_b · p_b.
    final da = wa.normal.dot(wa.point);
    final db = wb.normal.dot(wb.point);
    final x = (da * wb.normal.y - wa.normal.y * db) / det;
    final z = (wa.normal.x * db - da * wb.normal.x) / det;
    final c = Vec2(x, z);

    double reach(List<WallTap> taps, WallLine w) {
      var best = double.infinity;
      for (var i = 0; i < taps.length; i++) {
        if (w.outliers.contains(i)) continue;
        best = math.min(best, taps[i].posAr.xz.distanceTo(c));
      }
      return best;
    }

    if (reach(tapsA, wa) > maxReachM || reach(tapsB, wb) > maxReachM) {
      return const WallFitResult.failed(WallFitFailure.tooFar);
    }

    // Inside corner: each wall's taps lie in front of the other wall (the
    // room side both normals face). Outside corner / column: behind it.
    double side(List<WallTap> taps, WallLine own, WallLine other) {
      var s = 0.0;
      for (var i = 0; i < taps.length; i++) {
        if (own.outliers.contains(i)) continue;
        s += (taps[i].posAr.xz - c).dot(other.normal);
      }
      return s;
    }

    final inside = side(tapsA, wa, wb) + side(tapsB, wb, wa) >= 0;
    final between = math.acos(wa.normal.dot(wb.normal).clamp(-1.0, 1.0)) * 180 / math.pi;
    var fa = wa.normal;
    var fb = wb.normal;
    if (fa.cross(fb) < 0) (fa, fb) = (fb, fa);
    return WallFitResult.ok(WallCorner(
      posAr: Vec3(x, floorY, z),
      faceAAr: fa,
      faceBAr: fb,
      angleDeg: 180 - between,
      kind: inside ? 'inside' : 'outside',
      wallA: wa,
      wallB: wb,
    ));
  }

  /// Total least squares line through [pts]: (centroid, unit normal), or
  /// null for fewer than two distinct points.
  static (Vec2, Vec2)? _tls(List<Vec2> pts) {
    if (pts.length < 2) return null;
    var cx = 0.0;
    var cz = 0.0;
    for (final p in pts) {
      cx += p.x;
      cz += p.y;
    }
    cx /= pts.length;
    cz /= pts.length;
    var sxx = 0.0;
    var sxz = 0.0;
    var szz = 0.0;
    for (final p in pts) {
      final dx = p.x - cx;
      final dz = p.y - cz;
      sxx += dx * dx;
      sxz += dx * dz;
      szz += dz * dz;
    }
    if (sxx + szz < 1e-12) return null;
    // Major axis of the 2×2 scatter matrix; the normal is perpendicular.
    final theta = 0.5 * math.atan2(2 * sxz, sxx - szz);
    return (Vec2(cx, cz), Vec2(-math.sin(theta), math.cos(theta)));
  }

  static double _rms(List<Vec2> pts, (Vec2, Vec2) line) {
    if (pts.isEmpty) return 0;
    var s = 0.0;
    for (final p in pts) {
      final d = (p - line.$1).dot(line.$2);
      s += d * d;
    }
    return math.sqrt(s / pts.length);
  }

  /// Mean horizontal normal of the taps that have one, each flipped toward
  /// the camera first (depth normals come with either sign).
  static Vec2? _meanNormal(List<Vec3?> normals, Vec3? cameraAr, Vec2 at) {
    var sum = Vec2.zero;
    var n = 0;
    final toCam = cameraAr == null ? null : (cameraAr.xz - at);
    for (final raw in normals) {
      if (raw == null) continue;
      var h = raw.xz;
      if (h.length < 0.5) continue; // mostly vertical: no heading in it
      h = h.normalized;
      if (toCam != null && h.dot(toCam) < 0) h = -h;
      sum = sum + h;
      n++;
    }
    if (n == 0 || sum.length < 1e-6) return null;
    return sum.normalized;
  }
}
