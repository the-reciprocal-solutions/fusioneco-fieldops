import 'dart:math' as math;

import 'vec.dart';

/// "Can I drill here?" and "is this pipe in the wall?" from what a floor pack
/// already carries: the cut plan's walls (centre line + thickness, tile XZ)
/// and each element's bounding box (tile frame). No server call, no mesh.
///
/// Everything is in the **tile frame** (Y up, metres, CONTRACT C2); plan
/// points are (x, z) in a [Vec2]. Pure Dart so it is unit-tested without a
/// device (test/ar_drill_check_test.dart).
///
/// Honest limits, said in the UI too: the answer is only as good as the
/// model and today's alignment (± the fit residual), and bounding boxes are
/// conservative for diagonal runs. It is a pre-check before a detector, never
/// a replacement for one.

/// One wall of the cut plan: a centre-line polyline and its thickness.
class DrillWall {
  const DrillWall({required this.polyline, this.thicknessM = 0.2});

  /// Plan points (tile x, tile z).
  final List<Vec2> polyline;
  final double thicknessM;
}

/// A service the drill might hit: any MEP element, by its bounding box.
/// [ref] is whatever the caller wants back (the app passes its `ArFeature`).
class DrillService<T> {
  const DrillService({required this.ref, required this.bboxMin, required this.bboxMax});

  final T ref;
  final Vec3 bboxMin;
  final Vec3 bboxMax;
}

/// Where the camera-centre ray meets a wall face: the drill point.
class DrillHit {
  const DrillHit({
    required this.point,
    required this.faceNormal,
    required this.along,
    required this.wallIndex,
    required this.segmentIndex,
    required this.distanceM,
    required this.heightAboveFloorM,
    required this.thicknessM,
  });

  /// On the face, tile frame.
  final Vec3 point;

  /// Horizontal unit normal (x, z) of the face that was hit, pointing out of
  /// the wall towards the camera. "Behind the face" is along −[faceNormal].
  final Vec2 faceNormal;

  /// Horizontal unit direction (x, z) along the wall segment.
  final Vec2 along;
  final int wallIndex;
  final int segmentIndex;

  /// Camera → drill point.
  final double distanceM;
  final double heightAboveFloorM;
  final double thicknessM;
}

/// Where a service lies from the drill point, as the user looking at the
/// wall sees it. [behind] = the drill point is right over it.
enum DrillDirection { behind, above, below, left, right }

/// Green (clear), amber (15–30 cm) or red (< 15 cm).
enum DrillVerdict { safe, caution, danger }

class DrillFinding<T> {
  const DrillFinding({
    required this.ref,
    required this.planeDistanceM,
    required this.depthM,
    required this.direction,
  });

  final T ref;

  /// The gap between the drill point and the service's box, measured in the
  /// wall's plane (along the wall and up/down). 0 when the drill point is
  /// right over it.
  final double planeDistanceM;

  /// Behind the face to the service's near surface (≥ 0).
  final double depthM;
  final DrillDirection direction;
}

class DrillResult<T> {
  const DrillResult({this.hit, this.findings = const [], this.verdict});

  /// Null: the crosshair is not on a wall ("Point at a wall").
  final DrillHit? hit;

  /// Services behind the face within the search radius, nearest first.
  final List<DrillFinding<T>> findings;

  /// Null when there is no [hit].
  final DrillVerdict? verdict;

  DrillFinding<T>? get nearest => findings.isEmpty ? null : findings.first;
}

/// Where an element sits relative to the room: exposed, or concealed in a
/// wall, the floor, a slab or above the ceiling.
enum ServiceZone { room, inWall, inFloor, inSlab, aboveCeiling }

class ServicePlacement {
  const ServicePlacement({
    required this.zone,
    required this.bottomM,
    required this.topM,
    this.behindFaceM,
  });

  final ServiceZone zone;

  /// Box bottom and top above the finished floor.
  final double bottomM;
  final double topM;

  /// In a wall: the nearer face to the box's near surface.
  final double? behindFaceM;

  double get centreM => (bottomM + topM) / 2;
  bool get concealed => zone != ServiceZone.room;
}

class DrillCheck {
  const DrillCheck({
    this.wallHeightM = 3.2,
    this.dangerM = 0.15,
    this.cautionM = 0.30,
    this.maxDepthM = 0.35,
    this.frontToleranceM = 0.02,
    this.searchRadiusM = 1.0,
    this.minRangeM = 0.05,
    this.maxRangeM = 15,
    this.ceilingM = 2.9,
  });

  /// Walls are modelled floor to ~ceiling: a wall face is the rectangle from
  /// the finished floor up this far (the cut plan carries no heights).
  final double wallHeightM;

  /// Plane distance under which the verdict is red.
  final double dangerM;

  /// Plane distance under which the verdict is amber; services further than
  /// this don't change the verdict (they are still reported as "nearest").
  final double cautionM;

  /// How deep behind the face a drill can reach: a service deeper than this
  /// (the room next door) is ignored.
  final double maxDepthM;

  /// A service this far in front of the face still counts (surface-fixed
  /// cable clipped to the wall, a box that shares the face).
  final double frontToleranceM;

  /// "Nearest service 42 cm" looks this far; beyond it the wall is clear.
  final double searchRadiusM;
  final double minRangeM;
  final double maxRangeM;

  /// Box bottom this far above the finished floor = over a normal ceiling.
  final double ceilingM;

  DrillVerdict verdictFor(double? planeDistanceM) {
    if (planeDistanceM == null || planeDistanceM >= cautionM) return DrillVerdict.safe;
    return planeDistanceM < dangerM ? DrillVerdict.danger : DrillVerdict.caution;
  }

  /// Casts [origin] + s·[direction] (tile frame; [direction] need not be
  /// unit) against every wall face and returns the nearest hit in front of
  /// the camera, or null. Faces are vertical rectangles: the centre line
  /// ± thickness/2, from [floorY] up [wallHeightM]. Only the face on the
  /// camera's side of each segment can be the first thing the ray meets, so
  /// only that one is tested. A camera standing inside a wall's thickness
  /// (bad alignment) never hits that wall.
  DrillHit? cast({
    required Vec3 origin,
    required Vec3 direction,
    required List<DrillWall> walls,
    required double floorY,
  }) {
    final dir = direction.normalized;
    if (dir == Vec3.zero) return null;
    final dirXz = dir.xz;
    DrillHit? best;
    for (var wi = 0; wi < walls.length; wi++) {
      final wall = walls[wi];
      final half = wall.thicknessM / 2;
      for (var si = 0; si + 1 < wall.polyline.length; si++) {
        final a = wall.polyline[si];
        final b = wall.polyline[si + 1];
        final seg = b - a;
        final len = seg.length;
        if (len < 1e-3) continue;
        final u = seg * (1 / len);
        final n = Vec2(-u.y, u.x);
        final side = (origin.xz - a).dot(n);
        if (side.abs() <= half) continue;
        final sign = side > 0 ? 1.0 : -1.0;
        final dn = dirXz.dot(n);
        if (dn.abs() < 1e-9) continue;
        final s = (sign * half - side) / dn;
        if (s < minRangeM || s > maxRangeM) continue;
        if (best != null && s >= best.distanceM) continue;
        final p = origin + dir * s;
        final t = (p.xz - a).dot(u);
        if (t < -1e-6 || t > len + 1e-6) continue;
        final h = p.y - floorY;
        if (h < 0 || h > wallHeightM) continue;
        best = DrillHit(
          point: p,
          faceNormal: n * sign,
          along: u,
          wallIndex: wi,
          segmentIndex: si,
          distanceM: s,
          heightAboveFloorM: h,
          thicknessM: wall.thicknessM,
        );
      }
    }
    return best;
  }

  /// Services behind [hit]'s face, no deeper than [maxDepthM] and within
  /// [searchRadiusM] in the wall's plane, nearest first (ties: shallower
  /// first). Directions are as seen by someone facing the wall.
  List<DrillFinding<T>> near<T>(DrillHit hit, List<DrillService<T>> services) {
    final n = hit.faceNormal;
    // Facing the wall means looking along −n; that view's right is (n.z, −n.x)
    // in a right-handed, Y-up frame (−Z forward → +X right).
    final right = Vec2(n.y, -n.x);
    final px = hit.point.xz;
    final pr = px.dot(right);
    final out = <DrillFinding<T>>[];
    for (final svc in services) {
      final lo = _min(svc.bboxMin, svc.bboxMax);
      final hi = _max(svc.bboxMin, svc.bboxMax);
      var sMin = double.infinity, sMax = -double.infinity;
      var rMin = double.infinity, rMax = -double.infinity;
      for (final c in _cornersXz(lo, hi)) {
        final s = (c - px).dot(n);
        final r = c.dot(right);
        sMin = math.min(sMin, s);
        sMax = math.max(sMax, s);
        rMin = math.min(rMin, r);
        rMax = math.max(rMax, r);
      }
      // Behind the face is −s: the box spans [−sMax, −sMin] of depth.
      final depthNear = -sMax;
      final depthFar = -sMin;
      if (depthFar < -frontToleranceM || depthNear > maxDepthM) continue;
      final gr = _gap(pr, rMin, rMax);
      final gy = _gap(hit.point.y, lo.y, hi.y);
      final dist = math.sqrt(gr * gr + gy * gy);
      if (dist > searchRadiusM) continue;
      final DrillDirection direction;
      if (gr == 0 && gy == 0) {
        direction = DrillDirection.behind;
      } else if (gy >= gr) {
        direction = (lo.y + hi.y) / 2 > hit.point.y ? DrillDirection.above : DrillDirection.below;
      } else {
        direction = (rMin + rMax) / 2 > pr ? DrillDirection.right : DrillDirection.left;
      }
      out.add(DrillFinding(ref: svc.ref, planeDistanceM: dist, depthM: math.max(0, depthNear), direction: direction));
    }
    out.sort((a, b) {
      final c = a.planeDistanceM.compareTo(b.planeDistanceM);
      return c != 0 ? c : a.depthM.compareTo(b.depthM);
    });
    return out;
  }

  /// [cast] then [near], with the verdict from the nearest finding.
  DrillResult<T> run<T>({
    required Vec3 origin,
    required Vec3 direction,
    required List<DrillWall> walls,
    required double floorY,
    required List<DrillService<T>> services,
  }) {
    final hit = cast(origin: origin, direction: direction, walls: walls, floorY: floorY);
    if (hit == null) return DrillResult<T>();
    final findings = near(hit, services);
    return DrillResult<T>(
      hit: hit,
      findings: findings,
      verdict: verdictFor(findings.isEmpty ? null : findings.first.planeDistanceM),
    );
  }

  /// Is the box concealed, and where? In a wall when its footprint lies
  /// within a wall's thickness (a run *crossing* a wall spans both faces and
  /// is not "in" it); in the floor when it sits below the finished floor;
  /// over [ceilingM] it is in a slab when a slab box holds it, else above
  /// the ceiling. [slabs] are (min, max) boxes of slab elements.
  ServicePlacement place({
    required Vec3 bboxMin,
    required Vec3 bboxMax,
    required double floorY,
    List<DrillWall> walls = const [],
    List<(Vec3, Vec3)> slabs = const [],
    double toleranceM = 0.01,
  }) {
    final lo = _min(bboxMin, bboxMax);
    final hi = _max(bboxMin, bboxMax);
    final bottom = lo.y - floorY;
    final top = hi.y - floorY;
    if (bottom >= -toleranceM && top <= wallHeightM + toleranceM) {
      final behind = _behindWallFace(lo, hi, walls, toleranceM);
      if (behind != null) {
        return ServicePlacement(zone: ServiceZone.inWall, bottomM: bottom, topM: top, behindFaceM: behind);
      }
    }
    if (top <= 0.02) return ServicePlacement(zone: ServiceZone.inFloor, bottomM: bottom, topM: top);
    if (bottom >= ceilingM) {
      final cx = (lo.x + hi.x) / 2;
      final cz = (lo.z + hi.z) / 2;
      final cy = (lo.y + hi.y) / 2;
      for (final (sMin, sMax) in slabs) {
        final a = _min(sMin, sMax);
        final b = _max(sMin, sMax);
        if (cx >= a.x && cx <= b.x && cz >= a.z && cz <= b.z && cy >= a.y - toleranceM && cy <= b.y + toleranceM) {
          return ServicePlacement(zone: ServiceZone.inSlab, bottomM: bottom, topM: top);
        }
      }
      return ServicePlacement(zone: ServiceZone.aboveCeiling, bottomM: bottom, topM: top);
    }
    return ServicePlacement(zone: ServiceZone.room, bottomM: bottom, topM: top);
  }

  /// The smallest cover (nearer face → box) over every wall segment whose
  /// thickness holds the box's footprint, or null.
  static double? _behindWallFace(Vec3 lo, Vec3 hi, List<DrillWall> walls, double tol) {
    double? best;
    final corners = _cornersXz(lo, hi);
    final centre = Vec2((lo.x + hi.x) / 2, (lo.z + hi.z) / 2);
    for (final wall in walls) {
      final half = wall.thicknessM / 2;
      for (var i = 0; i + 1 < wall.polyline.length; i++) {
        final a = wall.polyline[i];
        final seg = wall.polyline[i + 1] - a;
        final len = seg.length;
        if (len < 1e-3) continue;
        final u = seg * (1 / len);
        final n = Vec2(-u.y, u.x);
        final t = (centre - a).dot(u);
        if (t < -tol || t > len + tol) continue;
        var pMin = double.infinity, pMax = -double.infinity;
        for (final c in corners) {
          final p = (c - a).dot(n);
          pMin = math.min(pMin, p);
          pMax = math.max(pMax, p);
        }
        if (pMin < -half - tol || pMax > half + tol) continue;
        final cover = math.max(0.0, math.min(pMin + half, half - pMax));
        if (best == null || cover < best) best = cover;
      }
    }
    return best;
  }

  static double _gap(double v, double lo, double hi) => v < lo ? lo - v : (v > hi ? v - hi : 0);

  static Vec3 _min(Vec3 a, Vec3 b) => Vec3(math.min(a.x, b.x), math.min(a.y, b.y), math.min(a.z, b.z));

  static Vec3 _max(Vec3 a, Vec3 b) => Vec3(math.max(a.x, b.x), math.max(a.y, b.y), math.max(a.z, b.z));

  static List<Vec2> _cornersXz(Vec3 lo, Vec3 hi) => [
    Vec2(lo.x, lo.z),
    Vec2(hi.x, lo.z),
    Vec2(hi.x, hi.z),
    Vec2(lo.x, hi.z),
  ];
}
