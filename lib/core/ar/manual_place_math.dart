import 'dart:math' as math;

import 'alignment_estimator.dart';
import 'ar_engine.dart' show ArPlane, ArRay;
import 'vec.dart';

/// "Place by hand" (docs/ar-implementation.md §2.7): the user loads the model
/// in front of them and moves, turns and sizes it with their fingers until
/// it sits on the room, instead of snapping corners. Owner, 2026-10-06:
/// "load the model and drag it to the corners and expand its size to fit the
/// room".
///
/// Everything here is pure and unit-tested (`test/ar_manual_place_math_test.dart`);
/// `ArManualPlaceController` only wires gestures and the engine to it.
///
/// Honesty rules that shape the maths:
/// - **True size is the default** and sticky: a pinch within ±3 % of 100 %
///   stays at 100 % ([ManualLimits.trueSizeDetentPct]), "True size" is one
///   tap, and a fit at any other size says so ([AlignmentFit.isTrueSize]).
/// - A hand placement is never "measured": its fit is
///   [AlignmentQuality.manual] with method `manual`, whatever the user did.

/// Tunables in one place.
abstract final class ManualLimits {
  /// Pinch range: half to double size. Beyond that the model is not this room.
  static const minScale = 0.5;
  static const maxScale = 2.0;

  /// A pinch that ends within this of 100 % is 100 % (true size is sticky).
  static const trueSizeDetentPct = 3.0;

  /// "Stretch to fit" per-axis range on top of the uniform size.
  static const minStretch = 0.8;
  static const maxStretch = 1.25;

  /// Twist soft-snap: within this of a wall-aligned heading, the model
  /// clicks onto it.
  static const yawSnapDeg = 4.0;

  /// Height offset range (a raised floor, a model whose datum is off).
  static const maxHeightM = 1.0;

  /// Long-press "fine mode": every gesture moves at a quarter speed.
  static const fineFactor = 0.25;

  /// "Snap corner": a model corner dropped within this of a detected room
  /// corner lands on it.
  static const magnetRadiusM = 0.30;

  /// Where the model first appears, ahead of the user.
  static const loadDistanceM = 1.5;

  /// Floor guess before the engine reports one: a standing phone's height.
  static const eyeHeightM = 1.45;

  /// "Snap to wall" looks at walls within these of a model face.
  static const wallSnapMaxAngleDeg = 25.0;
  static const wallSnapMaxDistM = 1.5;

  /// Nudge pad steps.
  static const nudgeM = 0.01;
  static const nudgeDeg = 1.0;

  /// Two-finger vertical drag: metres per logical pixel.
  static const heightPerPx = 0.002;

  /// A floor hit further than this from the camera is clamped (a finger near
  /// the horizon would otherwise fling the model across the building).
  static const maxReachM = 12.0;

  static const undoDepth = 30;
}

// ------------------------------------------------------------------- pose

/// Where the user has put the model: its pivot (the footprint's centre on
/// the finished floor) at [pos] on the AR floor plane, raised by
/// [heightM], turned by [yawRad] about +Y, drawn at [scale] (and stretched
/// by [stretchX]/[stretchZ] along the model's own X/Z when "Stretch to
/// fit" is on).
class ManualPose {
  const ManualPose({
    required this.pos,
    this.floorY = 0,
    this.heightM = 0,
    this.yawRad = 0,
    this.scale = 1,
    this.stretchX = 1,
    this.stretchZ = 1,
  });

  /// AR-world (x, z) of the pivot.
  final Vec2 pos;

  /// AR-world Y of the floor the model stands on.
  final double floorY;
  final double heightM;
  final double yawRad;
  final double scale;
  final double stretchX;
  final double stretchZ;

  Vec3 get pivotAr => Vec3(pos.x, floorY + heightM, pos.y);

  double get scalePct => scale * 100;

  bool get isTrueSize =>
      (scale - 1).abs() < 0.005 && (stretchX - 1).abs() < 0.005 && (stretchZ - 1).abs() < 0.005;

  bool get isStretched => (stretchX - 1).abs() >= 0.005 || (stretchZ - 1).abs() >= 0.005;

  /// `pAr = pivotAr + R(yaw) · diag(sx, s, sz) · (pTile − pivotTile)`.
  /// Rotation as [Mat4.fromYawTranslation] (CONTRACT C2).
  Mat4 arFromTile(Vec3 pivotTile) {
    final c = math.cos(yawRad);
    final s = math.sin(yawRad);
    final sx = scale * stretchX;
    final sy = scale;
    final sz = scale * stretchZ;
    // Columns of R·S.
    final c0 = Vec3(c * sx, 0, -s * sx);
    final c1 = Vec3(0, sy, 0);
    final c2 = Vec3(s * sz, 0, c * sz);
    final p = pivotAr;
    final t = p - (c0 * pivotTile.x + c1 * pivotTile.y + c2 * pivotTile.z);
    return Mat4([
      c0.x, c0.y, c0.z, 0, //
      c1.x, c1.y, c1.z, 0, //
      c2.x, c2.y, c2.z, 0, //
      t.x, t.y, t.z, 1, //
    ]);
  }

  ManualPose copyWith({
    Vec2? pos,
    double? floorY,
    double? heightM,
    double? yawRad,
    double? scale,
    double? stretchX,
    double? stretchZ,
  }) =>
      ManualPose(
        pos: pos ?? this.pos,
        floorY: floorY ?? this.floorY,
        heightM: heightM ?? this.heightM,
        yawRad: yawRad ?? this.yawRad,
        scale: scale ?? this.scale,
        stretchX: stretchX ?? this.stretchX,
        stretchZ: stretchZ ?? this.stretchZ,
      );

  /// The size part only, for "Last time: 112 %" on the next visit. Positions
  /// are not saved: a new AR session has a new world origin.
  Map<String, dynamic> sizeJson() => {'scale': scale, 'stretchX': stretchX, 'stretchZ': stretchZ, 'heightM': heightM};

  static ({double scale, double stretchX, double stretchZ, double heightM})? sizeFromJson(dynamic raw) {
    if (raw is! Map) return null;
    double? d(String k) => raw[k] is num ? (raw[k] as num).toDouble() : null;
    final scale = d('scale');
    if (scale == null || scale <= 0) return null;
    return (
      scale: scale.clamp(ManualLimits.minScale, ManualLimits.maxScale).toDouble(),
      stretchX: (d('stretchX') ?? 1).clamp(ManualLimits.minStretch, ManualLimits.maxStretch).toDouble(),
      stretchZ: (d('stretchZ') ?? 1).clamp(ManualLimits.minStretch, ManualLimits.maxStretch).toDouble(),
      heightM: (d('heightM') ?? 0).clamp(-ManualLimits.maxHeightM, ManualLimits.maxHeightM).toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ManualPose &&
      other.pos == pos &&
      other.floorY == floorY &&
      other.heightM == heightM &&
      other.yawRad == yawRad &&
      other.scale == scale &&
      other.stretchX == stretchX &&
      other.stretchZ == stretchZ;

  @override
  int get hashCode => Object.hash(pos, floorY, heightM, yawRad, scale, stretchX, stretchZ);

  @override
  String toString() => 'ManualPose(pos $pos, floor ${floorY.toStringAsFixed(3)}, h ${heightM.toStringAsFixed(3)}, '
      'yaw ${radToDeg(yawRad).toStringAsFixed(1)}°, scale ${scale.toStringAsFixed(3)}, '
      'stretch ${stretchX.toStringAsFixed(3)}×${stretchZ.toStringAsFixed(3)})';
}

/// A locked hand placement: what the session keeps and refits from.
class ManualPlacement {
  const ManualPlacement({required this.pose, required this.pivotTile});

  final ManualPose pose;
  final Vec3 pivotTile;

  Mat4 get arFromTile => pose.arFromTile(pivotTile);

  /// The tracker moved the anchor under the pivot by [deltaAr]: the model
  /// follows (re-anchoring on map corrections and relocalisation).
  ManualPlacement shifted(Vec3 deltaAr) => ManualPlacement(
        pose: pose.copyWith(pos: pose.pos + deltaAr.xz, floorY: pose.floorY + deltaAr.y),
        pivotTile: pivotTile,
      );

  /// The session's fit: [AlignmentQuality.manual], method `manual`, scale
  /// carried so the badge and measurements can say "not true size".
  AlignmentFit toFit() {
    final m = arFromTile;
    return AlignmentFit(
      yawRad: pose.yawRad,
      t: m.translation,
      arFromTile: m,
      maxResidualM: 0,
      residualsM: const {},
      outliers: const [],
      spreadM: 0,
      quality: AlignmentQuality.manual,
      observationCount: 0,
      method: 'manual',
      floorAnchored: true,
      scale: pose.scale,
      stretchX: pose.stretchX,
      stretchZ: pose.stretchZ,
    );
  }
}

// -------------------------------------------------------------- footprint

/// One wall face of the model in the tile frame's floor plane: segment
/// [a]–[b], [normal] pointing away from the wall body (into the room on
/// a room's side).
class ModelFace {
  const ModelFace(this.a, this.b, this.normal);
  final Vec2 a;
  final Vec2 b;
  final Vec2 normal;

  Vec2 get mid => (a + b) * 0.5;
  double get length => a.distanceTo(b);
}

/// What the overlay draws and the snaps use, from the floor pack: the
/// pivot, the outline, the corners offered as handles and the wall faces.
class ModelFootprint {
  const ModelFootprint({
    required this.pivotTile,
    required this.outline,
    required this.corners,
    required this.faces,
    this.mainHeadingRad = 0,
  });

  /// Footprint centre on the model's finished floor.
  final Vec3 pivotTile;

  /// Tile (x, z) polygon drawn as the outline.
  final List<Vec2> outline;

  /// Tile (x, z) corners offered for "Snap corner".
  final List<Vec2> corners;
  final List<ModelFace> faces;

  /// The model's dominant wall direction, modulo 90° (heading convention
  /// of [headingOf]): what "line the walls up" lines up.
  final double mainHeadingRad;

  double get floorTileY => pivotTile.y;

  Vec3 tile(Vec2 xz) => Vec3(xz.x, pivotTile.y, xz.y);

  /// Builds the footprint. [room] (the space the user is in, when the plan
  /// has one) wins over the plan [bounds]; [walls] are wall centre lines
  /// with [thicknesses]; [modelCorners] the manifest corners as (position,
  /// faceA, faceB, kind). Anything missing degrades: no plan → the
  /// corners' extent; nothing at all → a 4 m square at the origin.
  static ModelFootprint build({
    required double floorTileY,
    List<Vec2>? room,
    (Vec2 min, Vec2 max)? bounds,
    List<List<Vec2>> walls = const [],
    List<double> thicknesses = const [],
    List<(Vec2 pos, Vec2 faceA, Vec2 faceB, String kind)> modelCorners = const [],
  }) {
    var outline = room != null && room.length >= 3 ? List<Vec2>.of(room) : null;
    if (outline == null && bounds != null) {
      final (lo, hi) = bounds;
      outline = [lo, Vec2(hi.x, lo.y), hi, Vec2(lo.x, hi.y)];
    }
    if (outline == null && modelCorners.length >= 2) {
      var lo = modelCorners.first.$1, hi = modelCorners.first.$1;
      for (final c in modelCorners) {
        lo = Vec2(math.min(lo.x, c.$1.x), math.min(lo.y, c.$1.y));
        hi = Vec2(math.max(hi.x, c.$1.x), math.max(hi.y, c.$1.y));
      }
      if (hi.x - lo.x > 0.3 && hi.y - lo.y > 0.3) outline = [lo, Vec2(hi.x, lo.y), hi, Vec2(lo.x, hi.y)];
    }
    outline ??= const [Vec2(-2, -2), Vec2(2, -2), Vec2(2, 2), Vec2(-2, 2)];
    final centre = polygonCentroid(outline);

    final faces = <ModelFace>[];
    for (var i = 0; i < walls.length; i++) {
      final t = i < thicknesses.length && thicknesses[i] > 0 ? thicknesses[i] : 0.2;
      final line = walls[i];
      for (var j = 0; j + 1 < line.length; j++) {
        final a = line[j], b = line[j + 1];
        final d = b - a;
        if (d.length < 0.2) continue;
        final dir = d.normalized;
        final n = Vec2(-dir.y, dir.x);
        faces.add(ModelFace(a + n * (t / 2), b + n * (t / 2), n));
        faces.add(ModelFace(a - n * (t / 2), b - n * (t / 2), -n));
      }
    }
    if (faces.isEmpty) {
      // No wall lines: the outline's edges, facing into the room.
      for (var i = 0; i < outline.length; i++) {
        final a = outline[i], b = outline[(i + 1) % outline.length];
        final d = b - a;
        if (d.length < 0.2) continue;
        final dir = d.normalized;
        var n = Vec2(-dir.y, dir.x);
        if ((centre - (a + b) * 0.5).dot(n) < 0) n = -n;
        faces.add(ModelFace(a, b, n));
      }
    }

    // Handles: the inside corners of the room the outline covers (with a
    // little slack for a wall's thickness), else the outline's vertices.
    final inside = <Vec2>[
      for (final c in modelCorners)
        if (c.$4 == 'inside' && (_contains(outline, c.$1) || _distanceToPolygon(outline, c.$1) < 0.35)) c.$1,
    ];
    final corners = inside.length >= 3 ? _dedupe(inside, 0.1) : List<Vec2>.of(outline);

    return ModelFootprint(
      pivotTile: Vec3(centre.x, floorTileY, centre.y),
      outline: outline,
      corners: corners,
      faces: faces,
      mainHeadingRad: dominantHeading([for (final f in faces) (f.b - f.a, f.length)]),
    );
  }
}

/// Area centroid of a simple polygon (vertex mean for a degenerate one).
Vec2 polygonCentroid(List<Vec2> poly) {
  var a = 0.0, cx = 0.0, cz = 0.0;
  for (var i = 0; i < poly.length; i++) {
    final p = poly[i], q = poly[(i + 1) % poly.length];
    final cross = p.x * q.y - q.x * p.y;
    a += cross;
    cx += (p.x + q.x) * cross;
    cz += (p.y + q.y) * cross;
  }
  if (a.abs() < 1e-9) {
    var s = Vec2.zero;
    for (final p in poly) {
      s = s + p;
    }
    return poly.isEmpty ? Vec2.zero : s * (1 / poly.length);
  }
  return Vec2(cx / (3 * a), cz / (3 * a));
}

/// The dominant direction of weighted floor-plane directions, modulo 90°
/// (walls meet square): the circular mean of 4θ.
double dominantHeading(List<(Vec2 dir, double weight)> dirs) {
  var sx = 0.0, sy = 0.0;
  for (final (d, w) in dirs) {
    if (d.length < 1e-9) continue;
    final h = headingOf(d);
    sx += w * math.cos(4 * h);
    sy += w * math.sin(4 * h);
  }
  if (sx.abs() < 1e-12 && sy.abs() < 1e-12) return 0;
  return math.atan2(sy, sx) / 4;
}

bool _contains(List<Vec2> poly, Vec2 p) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.y > p.y) != (b.y > p.y)) {
      final dz = b.y - a.y;
      if (p.x < (b.x - a.x) * (p.y - a.y) / (dz == 0 ? 1e-9 : dz) + a.x) inside = !inside;
    }
  }
  return inside;
}

double _distanceToSegment(Vec2 p, Vec2 a, Vec2 b) {
  final ab = b - a;
  final l2 = ab.dot(ab);
  if (l2 < 1e-12) return p.distanceTo(a);
  final t = ((p - a).dot(ab) / l2).clamp(0.0, 1.0);
  return p.distanceTo(a + ab * t);
}

double _distanceToPolygon(List<Vec2> poly, Vec2 p) {
  var best = double.infinity;
  for (var i = 0; i < poly.length; i++) {
    best = math.min(best, _distanceToSegment(p, poly[i], poly[(i + 1) % poly.length]));
  }
  return best;
}

List<Vec2> _dedupe(List<Vec2> points, double minGap) {
  final out = <Vec2>[];
  for (final p in points) {
    if (out.every((q) => q.distanceTo(p) >= minGap)) out.add(p);
  }
  return out;
}

// --------------------------------------------------------------- gestures

/// The gesture → pose maths. Every function takes the pose at the start of
/// the gesture and the gesture so far, so a slow frame never accumulates
/// error.
abstract final class ManualGestures {
  /// Where [ray] meets the horizontal plane `y = planeY`; null when it
  /// points away from it. Hits beyond [ManualLimits.maxReachM] are pulled
  /// back to that distance along the ray's floor direction.
  static Vec3? floorHit(ArRay ray, double planeY) {
    final d = ray.dirAr;
    if (d.y.abs() < 1e-6) return null;
    final t = (planeY - ray.originAr.y) / d.y;
    if (t <= 0) return null;
    final hit = ray.originAr + d * t;
    final flat = hit.xz - ray.originAr.xz;
    if (flat.length <= ManualLimits.maxReachM) return hit;
    final p = ray.originAr.xz + flat.normalized * ManualLimits.maxReachM;
    return Vec3(p.x, planeY, p.y);
  }

  /// One-finger drag: the model follows the finger on its base plane.
  static ManualPose dragged(ManualPose start, Vec3 hitStart, Vec3 hitNow, {bool fine = false}) {
    final k = fine ? ManualLimits.fineFactor : 1.0;
    return start.copyWith(pos: start.pos + (hitNow.xz - hitStart.xz) * k);
  }

  /// Two-finger twist. Flutter's rotation is clockwise-positive on screen;
  /// seen from above, clockwise is a negative turn about +Y.
  static double twisted(double startYaw, double rotationRad, {bool fine = false}) =>
      wrapAngle(startYaw - rotationRad * (fine ? ManualLimits.fineFactor : 1));

  /// Pinch: uniform size, clamped to 50–200 %, sticky at 100 %.
  static double pinched(double startScale, double gestureScale, {bool fine = false}) {
    final g = gestureScale <= 0 ? 1.0 : gestureScale;
    final s = (startScale * math.pow(g, fine ? ManualLimits.fineFactor : 1)).clamp(ManualLimits.minScale, ManualLimits.maxScale).toDouble();
    return snapTrueSize(s);
  }

  /// Within ±[ManualLimits.trueSizeDetentPct] % of 100 % is 100 %.
  static double snapTrueSize(double s) => ((s - 1).abs() * 100 <= ManualLimits.trueSizeDetentPct) ? 1.0 : s;

  /// Two-finger vertical drag: up raises the model.
  static double heightDragged(double startHeight, double dyPx, {bool fine = false}) =>
      (startHeight - dyPx * ManualLimits.heightPerPx * (fine ? ManualLimits.fineFactor : 1))
          .clamp(-ManualLimits.maxHeightM, ManualLimits.maxHeightM)
          .toDouble();

  /// Headings (modulo 90°) at which the model's walls run along a detected
  /// wall: one per wall.
  static List<double> wallAlignedYaws(double modelMainHeading, Iterable<ArPlane> walls) => [
        for (final w in walls)
          if (Vec2(w.normalAr.x, w.normalAr.z).length > 0.5) headingOf(Vec2(w.normalAr.x, w.normalAr.z)) - modelMainHeading,
      ];

  /// Soft snap: when [yaw] is within [windowDeg] of any aligned heading
  /// (each counts at 0/90/180/270°), it clicks onto it.
  static ({double yaw, bool snapped}) softSnapYaw(double yaw, List<double> aligned, {double windowDeg = ManualLimits.yawSnapDeg}) {
    double? best;
    var bestAbs = degToRad(windowDeg);
    for (final a in aligned) {
      final d = quarterDiff(yaw, a);
      if (d.abs() <= bestAbs) {
        bestAbs = d.abs();
        best = d;
      }
    }
    return best == null ? (yaw: yaw, snapped: false) : (yaw: wrapAngle(yaw - best), snapped: true);
  }

  /// `a − b` folded into (−45°, 45°].
  static double quarterDiff(double a, double b) {
    const q = math.pi / 2;
    var d = (a - b) % q;
    if (d > q / 2) d -= q;
    if (d <= -q / 2) d += q;
    return d;
  }

  /// The pose with the same visible size/turn as [after] but moved so the
  /// tile point [tilePoint] stays where [before] had it on the floor:
  /// pinching or twisting about a pinned corner instead of the centre.
  static ManualPose keepFixed(ManualPose before, ManualPose after, Vec3 tilePoint, Vec3 pivotTile) {
    final wBefore = before.arFromTile(pivotTile).transformPoint(tilePoint);
    final wAfter = after.arFromTile(pivotTile).transformPoint(tilePoint);
    return after.copyWith(pos: after.pos + (wBefore.xz - wAfter.xz));
  }

  /// Nudge pad: [right]/[away] in centimetres-sized steps relative to the
  /// camera's heading (so "→" moves the model to the user's right).
  static ManualPose nudged(ManualPose p, {double rightM = 0, double awayM = 0, double upM = 0, double turnDeg = 0, Vec3? cameraForwardAr}) {
    var fwd = cameraForwardAr == null ? const Vec2(0, -1) : Vec2(cameraForwardAr.x, cameraForwardAr.z);
    fwd = fwd.length < 1e-6 ? const Vec2(0, -1) : fwd.normalized;
    // Right of the view direction, seen from above with −Z ahead: (−fz, fx).
    final right = Vec2(-fwd.y, fwd.x);
    return p.copyWith(
      pos: p.pos + right * rightM + fwd * awayM,
      heightM: (p.heightM + upM).clamp(-ManualLimits.maxHeightM, ManualLimits.maxHeightM).toDouble(),
      // "Turn right" = clockwise from above = negative yaw.
      yawRad: wrapAngle(p.yawRad - degToRad(turnDeg)),
    );
  }

  /// Where the model first appears: [ManualLimits.loadDistanceM] ahead of
  /// the user on the floor, its plan-up (−Z) pointing the way they look, so
  /// the room reads the same way round as the plan. With walls detected the
  /// heading is squared to the nearest one.
  static ManualPose initialPose({
    required Vec3 cameraAr,
    required Vec3 forwardAr,
    double? floorY,
    double modelMainHeading = 0,
    Iterable<ArPlane> walls = const [],
  }) {
    var fwd = Vec2(forwardAr.x, forwardAr.z);
    fwd = fwd.length < 1e-6 ? const Vec2(0, -1) : fwd.normalized;
    final pos = cameraAr.xz + fwd * ManualLimits.loadDistanceM;
    var yaw = wrapAngle(headingOf(fwd) - headingOf(const Vec2(0, -1)));
    final aligned = wallAlignedYaws(modelMainHeading, walls);
    if (aligned.isNotEmpty) yaw = softSnapYaw(yaw, aligned, windowDeg: 45).yaw;
    return ManualPose(pos: pos, floorY: floorY ?? cameraAr.y - ManualLimits.eyeHeightM, yawRad: yaw);
  }
}

/// Two fingers: twist-and-pinch, or a vertical drag for height. Decided once
/// per gesture, on the first clear movement, so a pinch never also lifts the
/// model and a height drag never turns it.
enum TwoFingerMode { undecided, transform, height }

abstract final class TwoFingerClassifier {
  static const twistDeg = 6.0;
  static const pinchRatio = 0.06;
  static const liftPx = 24.0;

  static TwoFingerMode classify({required double rotationRad, required double scale, required double dxPx, required double dyPx}) {
    if (radToDeg(rotationRad).abs() >= twistDeg || (math.log(scale <= 0 ? 1 : scale)).abs() >= pinchRatio) {
      return TwoFingerMode.transform;
    }
    if (dyPx.abs() >= liftPx && dyPx.abs() >= 2 * dxPx.abs()) return TwoFingerMode.height;
    return TwoFingerMode.undecided;
  }
}

// ------------------------------------------------------------ fit helpers

/// The result of "Snap to wall".
class WallSnap {
  const WallSnap({required this.pose, required this.wall, required this.face, required this.turnedRad, required this.movedM});
  final ManualPose pose;
  final ArPlane wall;
  final ModelFace face;
  final double turnedRad;
  final double movedM;
}

abstract final class ManualSnaps {
  /// "Snap to wall": the model face that best matches a detected wall (close
  /// in heading and distance, overlapping it along the wall) turns parallel
  /// to it and slides onto it. Null when no face is within
  /// [ManualLimits.wallSnapMaxAngleDeg] and [ManualLimits.wallSnapMaxDistM]
  /// of any wall. A stretched model's faces are turned by the yaw only
  /// (stretch is along the model's own axes, so faces stay parallel).
  static WallSnap? snapToWall(ManualPose pose, ModelFootprint fp, Iterable<ArPlane> walls) {
    final m = pose.arFromTile(fp.pivotTile);
    final maxAngle = degToRad(ManualLimits.wallSnapMaxAngleDeg);
    WallSnap? best;
    var bestScore = double.infinity;
    for (final w in walls) {
      final nW0 = Vec2(w.normalAr.x, w.normalAr.z);
      if (nW0.length < 0.5) continue;
      final nW = nW0.normalized;
      final pW = w.centerAr.xz;
      final along = Vec2(-nW.y, nW.x);
      for (final f in fp.faces) {
        final nF = rotateXz(f.normal, pose.yawRad);
        final turn = wrapAngle(headingOf(nW) - headingOf(nF));
        if (turn.abs() > maxAngle) continue;
        final mid = m.transformPoint(fp.tile(f.mid)).xz;
        final dist = (mid - pW).dot(nW);
        if (dist.abs() > ManualLimits.wallSnapMaxDistM) continue;
        // Along the wall: how far the face's middle is beyond the wall's
        // measured extent (0 when it overlaps).
        var lateral = 0.0;
        final seg = w.segment;
        if (seg != null) {
          final s0 = (seg.$1 - pW).dot(along), s1 = (seg.$2 - pW).dot(along);
          final u = (mid - pW).dot(along);
          final lo = math.min(s0, s1), hi = math.max(s0, s1);
          lateral = u < lo ? lo - u : (u > hi ? u - hi : 0);
        } else {
          lateral = math.max(0, (mid - pW).dot(along).abs() - math.max(0.5, w.widthM / 2));
        }
        final score = turn.abs() / maxAngle + dist.abs() / ManualLimits.wallSnapMaxDistM + lateral / 2;
        if (score >= bestScore) continue;
        // Turn about the pivot, then slide along the wall normal so the face
        // lies in the wall plane.
        final turned = pose.copyWith(yawRad: wrapAngle(pose.yawRad + turn));
        final mid1 = turned.arFromTile(fp.pivotTile).transformPoint(fp.tile(f.mid)).xz;
        final d1 = (mid1 - pW).dot(nW);
        final moved = turned.copyWith(pos: turned.pos - nW * d1);
        bestScore = score;
        best = WallSnap(pose: moved, wall: w, face: f, turnedRad: turn, movedM: d1.abs());
      }
    }
    return best;
  }

  /// Room corners from detected walls: where two walls meeting at 60–120°
  /// cross, near both walls' measured extents (within [slackM]). AR (x, z).
  static List<Vec2> roomCorners(Iterable<ArPlane> walls, {double slackM = 0.6}) {
    final list = [
      for (final w in walls)
        if (Vec2(w.normalAr.x, w.normalAr.z).length > 0.5) w,
    ];
    final out = <Vec2>[];
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        final a = list[i], b = list[j];
        final na = Vec2(a.normalAr.x, a.normalAr.z).normalized;
        final nb = Vec2(b.normalAr.x, b.normalAr.z).normalized;
        if (na.dot(nb).abs() > 0.5) continue; // not 60–120°
        // (p − ca)·na = 0, (p − cb)·nb = 0
        final det = na.x * nb.y - na.y * nb.x;
        if (det.abs() < 1e-6) continue;
        final ra = na.dot(a.centerAr.xz), rb = nb.dot(b.centerAr.xz);
        final p = Vec2((ra * nb.y - rb * na.y) / det, (na.x * rb - nb.x * ra) / det);
        if (!_near(a, p, slackM) || !_near(b, p, slackM)) continue;
        if (out.every((q) => q.distanceTo(p) > 0.1)) out.add(p);
      }
    }
    return out;
  }

  static bool _near(ArPlane w, Vec2 p, double slack) {
    final seg = w.segment;
    if (seg != null) return _distanceToSegment(p, seg.$1, seg.$2) <= slack;
    return p.distanceTo(w.centerAr.xz) <= math.max(3.0, w.widthM / 2 + slack);
  }

  /// The detected corner nearest [p] within [radiusM], or null.
  static Vec2? magnet(Vec2 p, Iterable<Vec2> candidates, {double radiusM = ManualLimits.magnetRadiusM}) {
    Vec2? best;
    var bestD = radiusM;
    for (final c in candidates) {
      final d = c.distanceTo(p);
      if (d <= bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }
}

// ------------------------------------------------------------ undo / redo

/// A small undo/redo stack of whole poses. [record] the pose *before* a
/// change; a new change clears redo.
class UndoStack<T> {
  UndoStack({this.capacity = ManualLimits.undoDepth});

  final int capacity;
  final _undo = <T>[];
  final _redo = <T>[];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoDepth => _undo.length;

  void record(T before) {
    _undo.add(before);
    if (_undo.length > capacity) _undo.removeAt(0);
    _redo.clear();
  }

  /// Returns the pose to go back to (and keeps [current] for redo), or null.
  T? undo(T current) {
    if (_undo.isEmpty) return null;
    _redo.add(current);
    return _undo.removeLast();
  }

  T? redo(T current) {
    if (_redo.isEmpty) return null;
    _undo.add(current);
    return _redo.removeLast();
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}

// ------------------------------------------------------- coach and advice

/// The guided coach line for each step.
enum ManualCoachStep { floor, drag, twist, pinch, lock }

abstract final class ManualCoach {
  static ManualCoachStep step({required bool placed, required bool moved, required bool turned, required bool sized}) {
    if (!placed) return ManualCoachStep.floor;
    if (!moved) return ManualCoachStep.drag;
    if (!turned) return ManualCoachStep.twist;
    if (!sized) return ManualCoachStep.pinch;
    return ManualCoachStep.lock;
  }

  static String key(ManualCoachStep s) => switch (s) {
        ManualCoachStep.floor => 'ar.manual.coach.floor',
        ManualCoachStep.drag => 'ar.manual.coach.drag',
        ManualCoachStep.twist => 'ar.manual.coach.twist',
        ManualCoachStep.pinch => 'ar.manual.coach.pinch',
        ManualCoachStep.lock => 'ar.manual.coach.lock',
      };
}

/// When the method chooser suggests "Place by hand" first.
abstract final class ManualAdvice {
  /// Fewer usable corners than this: the corner method has little to snap.
  static const fewCorners = 3;

  /// Corner attempts that failed (a mismatch, plain walls, no corner found)
  /// before hand placement is suggested instead.
  static const failuresBeforeSuggest = 2;

  static bool recommend({required int corners, required int cornerFailures, required bool boardFirst}) {
    if (cornerFailures >= failuresBeforeSuggest) return true;
    return !boardFirst && corners < fewCorners;
  }
}

// --------------------------------------------------------- pinhole camera

/// A plain pinhole camera, for Demo mode and the fake engine: rays through
/// view points and the projection back, consistent with each other. Never
/// used on a device (the engine knows the real intrinsics).
class PinholeCamera {
  PinholeCamera({required this.arFromCamera, required this.width, required this.height, this.vFovDeg = 60});

  /// Camera → AR world (rigid; looks down its −Z, Y up).
  final Mat4 arFromCamera;
  final double width;
  final double height;
  final double vFovDeg;

  double get _f => 1 / math.tan(degToRad(vFovDeg) / 2);
  double get _aspect => width / math.max(1, height);

  /// A camera at [eye] looking at [target], level (no roll).
  factory PinholeCamera.lookingAt(Vec3 eye, Vec3 target, {required double width, required double height, double vFovDeg = 60}) {
    var f = target - eye;
    f = f.length < 1e-9 ? const Vec3(0, 0, -1) : f.normalized;
    var r = f.cross(Vec3.up);
    r = r.length < 1e-6 ? const Vec3(1, 0, 0) : r.normalized;
    final u = r.cross(f);
    return PinholeCamera(
      arFromCamera: Mat4([r.x, r.y, r.z, 0, u.x, u.y, u.z, 0, -f.x, -f.y, -f.z, 0, eye.x, eye.y, eye.z, 1]),
      width: width,
      height: height,
      vFovDeg: vFovDeg,
    );
  }

  ArRay ray(double x, double y) {
    final nx = 2 * x / math.max(1, width) - 1;
    final ny = 1 - 2 * y / math.max(1, height);
    final dCam = Vec3(nx * _aspect / _f, ny / _f, -1).normalized;
    return ArRay(originAr: arFromCamera.translation, dirAr: arFromCamera.transformDir(dCam).normalized);
  }

  /// View point of an AR-world point, `(x, y, onScreen)`; null behind the camera.
  (double, double, bool)? project(Vec3 worldAr) {
    final c = arFromCamera.invertRigid().transformPoint(worldAr);
    if (c.z > -1e-3) return null;
    final nx = (c.x / -c.z) * _f / _aspect;
    final ny = (c.y / -c.z) * _f;
    final x = (nx + 1) / 2 * width;
    final y = (1 - ny) / 2 * height;
    return (x, y, x >= 0 && x <= width && y >= 0 && y <= height);
  }
}
