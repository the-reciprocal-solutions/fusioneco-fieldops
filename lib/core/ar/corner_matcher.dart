import 'dart:math' as math;

import '../network/envelope.dart';
import 'alignment_estimator.dart';
import 'ar_engine.dart' show CornerSeenEvent;
import 'vec.dart';

/// A corner the geometry build extracted and ranked (manifest `corners`,
/// server table `bim_ar_corners`; docs/ar-setup-and-gamma-parity.md §2.2).
///
/// [posTile] is where the corner line meets the floor **datum** (the
/// modelled slab top); [faceA]/[faceB] are the two faces' horizontal
/// normals `[nx, nz]`, pointing out of the wall or column material — i.e.
/// toward where a person can stand.
class CornerCandidate {
  const CornerCandidate({
    required this.id,
    required this.posTile,
    required this.faceA,
    required this.faceB,
    required this.angleDeg,
    required this.kind,
    this.structural = false,
    this.rank = 0,
    this.label = '',
  });

  final String id;
  final Vec3 posTile;
  final Vec2 faceA;
  final Vec2 faceB;
  final double angleDeg;

  /// `inside | outside | column`.
  final String kind;
  final bool structural;
  final double rank;
  final String label;

  /// Null for a row missing its id, position or faces — a candidate the app
  /// can't match is better skipped than drawn at the origin.
  static CornerCandidate? fromJson(Map<String, dynamic> json) {
    final id = firstNonEmpty([json['id']]);
    final pos = Vec3.tryParse(json['pos'] ?? json['posTile']);
    final a = Vec2.tryParse(json['faceA']);
    final b = Vec2.tryParse(json['faceB']);
    if (id == null || pos == null || a == null || b == null) return null;
    return CornerCandidate(
      id: id,
      posTile: pos,
      faceA: a,
      faceB: b,
      angleDeg: asDouble(json['angleDeg']) ?? 90,
      kind: json['kind']?.toString() ?? 'inside',
      structural: asBool(json['structural']) ?? false,
      rank: asDouble(json['rank']) ?? 0,
      label: json['label']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'pos': posTile.toList(),
        'faceA': faceA.toList(),
        'faceB': faceB.toList(),
        'angleDeg': angleDeg,
        'kind': kind,
        'structural': structural,
        'rank': rank,
        'label': label,
      };

  @override
  String toString() => 'CornerCandidate($id, $kind ${angleDeg.round()}°, $label)';
}

/// What the native engine snapped under the pin (`CornerSeenEvent`, or the
/// result of `ArEngine.detectCornerAt`). Face directions are horizontal
/// normals in the AR world; the engine orients them toward the camera, and
/// [CornerMatcher] re-orients them when it knows the camera position.
class DetectedCorner {
  const DetectedCorner({
    required this.posAr,
    required this.faceAAr,
    required this.faceBAr,
    required this.angleDeg,
    required this.kind,
    this.method = 'planes',
    this.surfaceResidualMm,
  });

  factory DetectedCorner.fromSeen(CornerSeenEvent e) => DetectedCorner(
        posAr: e.posAr,
        faceAAr: e.faceAAr,
        faceBAr: e.faceBAr,
        angleDeg: e.angleDeg,
        kind: e.kind,
        method: e.method,
        surfaceResidualMm: e.surfaceResidualMm,
      );

  final Vec3 posAr;
  final Vec2 faceAAr;
  final Vec2 faceBAr;
  final double angleDeg;
  final String kind;

  /// `lidar | planes | floorTap` — sets the observation's σ.
  final String method;

  /// The engine's LiDAR check of the corner line (mm, iOS), or null.
  final double? surfaceResidualMm;
}

/// A candidate within reach of a detected corner, nearest first.
class CornerMatch {
  const CornerMatch({required this.candidate, required this.distanceM});

  final CornerCandidate candidate;

  /// Horizontal distance between where the current fit predicts the
  /// candidate and where the corner was actually snapped.
  final double distanceM;
}

enum ShapeFallbackKind { matches, switched, nearbyOtherShape, noneOfShape }

/// [CornerMatcher.fallbackFor]'s answer.
class ShapeFallback {
  const ShapeFallback({
    required this.kind,
    required this.snappedShape,
    this.candidate,
    this.distanceM,
    this.nearbyShape,
    this.sameShape = const [],
  });

  final ShapeFallbackKind kind;

  /// The corner to use ([ShapeFallbackKind.matches] / `switched`), or the
  /// nearest same-shape one (`nearbyOtherShape`).
  final CornerCandidate? candidate;
  final double? distanceM;

  /// `inside | outside` — what the user is standing at.
  final String snappedShape;

  /// `inside | outside` — the shape of the corner they picked.
  final String? nearbyShape;

  /// Every floor corner with the snapped shape, nearest first.
  final List<CornerCandidate> sameShape;
}

/// Turns snapped corners into estimator observations and picks which model
/// corner a snap is (docs/ar-setup-and-gamma-parity.md §2.4, AR-41).
///
/// - **Corner A** is chosen by the user (one tap on the mini plan), so
///   [firstCorner] only has to pair its faces.
/// - **Corner B** is matched automatically ([matchSecond]): with A placed,
///   the fit predicts where every candidate should appear, and the snap is
///   the nearest candidate of the same shape within 1 m.
class CornerMatcher {
  const CornerMatcher({this.floorFinishOffsetM = 0});

  /// The floor's finish above the modelled slab (raised access floor,
  /// screed), set once per floor in the web admin. The phone snaps the
  /// *finished* floor, so candidates are raised by this much before fitting.
  final double floorFinishOffsetM;

  /// Two corners are the "same shape" within this angle — the default, for
  /// corners fitted from tracked planes ([angleToleranceFor] per method).
  static const angleToleranceDeg = 15.0;

  /// Angle tolerance per snap method (2026-10-06, first iPhone run: an
  /// inside corner snapped at 93° against a model at 90°).
  ///
  /// The tolerance only has to tell a 90° corner from a splayed one (the
  /// extractor keeps 30–150°, and real splays are 120–135°), while inside vs
  /// outside is decided by `kind`, not the angle. What it must absorb:
  /// - real rooms are out of square: 1–3° is normal for plastered brick
  ///   (the owner's bedroom read 93°);
  /// - the depth sensor's wall fit adds about ±1–2° on painted walls;
  /// - tracked planes alone (no depth sensor) wobble ±3–5° while they grow;
  /// - wall taps and a floor tap borrow one wall and guess the other.
  ///
  /// So 10° for a depth-sensor snap (3° out of square + 2° fit, twice over),
  /// 15° for tracked planes, 20° for the rough methods. All stay far below
  /// the 30°+ gap to a splayed corner. The server's own "same shape" test
  /// uses 10° on exact model geometry (cornerExtractor.ts `sameShape`).
  static double angleToleranceFor(String method) => switch (method) {
        'lidar' || 'depth' => 10.0,
        'planes' || 'plane' => angleToleranceDeg,
        _ => 20.0,
      };

  /// Corners at least this far apart can turn the badge green (a 3 m pair
  /// has the 1.5 m spread the estimator needs).
  static const lockSeparationM = 3.0;

  /// A shape-matching corner this close to where the user meant (the corner
  /// they picked, or where the camera is) is taken without asking: about
  /// one room. Farther away it is a guess, so the screen explains instead.
  static const autoPickRadiusM = 8.0;

  /// The model point a snap of [c] is compared with: the corner line at the
  /// finished floor.
  Vec3 modelPoint(CornerCandidate c) =>
      Vec3(c.posTile.x, c.posTile.y + floorFinishOffsetM, c.posTile.z);

  /// `inside` or `outside` — a column's edge is an outside corner.
  static String shapeOf(String kind) => kind == 'column' ? 'outside' : (kind == 'inside' ? 'inside' : 'outside');

  /// Same kind (a column's edge counts as an outside corner) and angle
  /// within [angleToleranceFor] the snap's method.
  bool shapeMatches(DetectedCorner d, CornerCandidate c) {
    if (shapeOf(d.kind) != shapeOf(c.kind)) return false;
    return (d.angleDeg - c.angleDeg).abs() <= angleToleranceFor(d.method);
  }

  /// What to do with a corner-A snap whose shape differs from the corner the
  /// user picked ([chosen]). Searches **every** corner of the floor
  /// ([floorCorners]), not just the room's short list, and prefers the one
  /// nearest [near] (the last known camera position, else the picked
  /// corner — where the user said they are), then the best ranked.
  ///
  /// - [ShapeFallbackKind.matches]: the snap fits [chosen]; nothing to do.
  /// - [ShapeFallbackKind.switched]: a same-shape corner within
  ///   [autoPickRadiusM]; use it and say which.
  /// - [ShapeFallbackKind.nearbyOtherShape]: same-shape corners exist, but
  ///   only far away: ask the user to tap one on the plan.
  /// - [ShapeFallbackKind.noneOfShape]: the model has no corner of that
  ///   shape at all — most likely the wrong floor or model for this room.
  ShapeFallback fallbackFor(
    DetectedCorner d,
    CornerCandidate chosen,
    List<CornerCandidate> floorCorners, {
    Vec3? near,
  }) {
    if (shapeMatches(d, chosen)) {
      return ShapeFallback(kind: ShapeFallbackKind.matches, candidate: chosen, snappedShape: shapeOf(d.kind));
    }
    final ref = (near ?? chosen.posTile).xz;
    final same = [for (final c in floorCorners) if (shapeMatches(d, c)) c];
    // Which shape the user sees around the corner they picked: the reason
    // given on screen ("this model's corners near there are column corners").
    final nearbyShape = shapeOf(chosen.kind);
    if (same.isEmpty) {
      return ShapeFallback(
        kind: ShapeFallbackKind.noneOfShape,
        snappedShape: shapeOf(d.kind),
        nearbyShape: nearbyShape,
      );
    }
    double dist(CornerCandidate c) => c.posTile.xz.distanceTo(ref);
    same.sort((a, b) {
      final byDist = dist(a).compareTo(dist(b));
      // Within 0.5 m of each other the better-ranked corner wins.
      if ((dist(a) - dist(b)).abs() > 0.5) return byDist;
      final byRank = b.rank.compareTo(a.rank);
      return byRank != 0 ? byRank : byDist;
    });
    final best = same.first;
    final d0 = dist(best);
    return ShapeFallback(
      kind: d0 <= autoPickRadiusM ? ShapeFallbackKind.switched : ShapeFallbackKind.nearbyOtherShape,
      candidate: best,
      distanceM: d0,
      snappedShape: shapeOf(d.kind),
      nearbyShape: nearbyShape,
      sameShape: same,
    );
  }

  /// The first corner, chosen by the user. One corner gives position **and**
  /// heading, because its two faces fix the direction.
  ///
  /// On a 90° corner the two ways of pairing detected faces with model faces
  /// are 90° apart. The side the camera is on settles it: both faces are
  /// oriented toward [cameraAr] (for an inside corner the camera stands
  /// inside the angle; a column shows the camera the two faces that point at
  /// it), and then only one pairing gives both faces the same heading.
  CornerObs firstCorner(
    DetectedCorner d,
    CornerCandidate chosen, {
    Vec3? cameraAr,
  }) =>
      observe(d, chosen, cameraAr: cameraAr);

  /// Any corner snap as an observation. [yawPrior] (the current fit's
  /// heading) breaks a pairing tie on a later corner; [cameraAr] orients the
  /// detected faces as in [firstCorner].
  CornerObs observe(
    DetectedCorner d,
    CornerCandidate c, {
    Vec3? cameraAr,
    double? yawPrior,
    double distanceSinceM = 0,
  }) {
    var arA = d.faceAAr.normalized;
    var arB = d.faceBAr.normalized;
    if (cameraAr != null) {
      final toCamera = (cameraAr - d.posAr).xz;
      if (toCamera.length > 1e-6) {
        if (arA.dot(toCamera) < 0) arA = -arA;
        if (arB.dot(toCamera) < 0) arB = -arB;
      }
    }
    final (pairedA, pairedB) = _pair(c.faceA, c.faceB, arA, arB, yawPrior);
    return CornerObs(
      id: c.id,
      aAr: d.posAr,
      bTile: modelPoint(c),
      sigmaM: ArSigma.forCorner(d.method),
      distanceSinceM: distanceSinceM,
      faceAAr: pairedA,
      faceBAr: pairedB,
      faceATile: c.faceA,
      faceBTile: c.faceB,
      method: d.method,
    );
  }

  /// Chooses which detected face is model face A. Each pairing implies a
  /// heading per face; the right pairing has the two agree (and, with a
  /// prior, agree with the current fit).
  static (Vec2, Vec2) _pair(
    Vec2 tileA,
    Vec2 tileB,
    Vec2 arA,
    Vec2 arB,
    double? yawPrior,
  ) {
    double score(Vec2 forA, Vec2 forB) {
      final ya = headingOf(forA) - headingOf(tileA);
      final yb = headingOf(forB) - headingOf(tileB);
      var s = wrapAngle(ya - yb).abs();
      if (yawPrior != null) {
        final mean = math.atan2(
          math.sin(ya) + math.sin(yb),
          math.cos(ya) + math.cos(yb),
        );
        s += wrapAngle(mean - yawPrior).abs();
      }
      return s;
    }

    final straight = score(arA, arB);
    final swapped = score(arB, arA);
    return swapped < straight - 1e-9 ? (arB, arA) : (arA, arB);
  }

  /// Every candidate of the same shape whose predicted position is within
  /// [maxDistM] of the snap, nearest first. Two or more means the snap is
  /// ambiguous: the screen asks with two big buttons instead of guessing.
  List<CornerMatch> candidatesNear(
    DetectedCorner d,
    AlignmentFit fit,
    List<CornerCandidate> cands, {
    double maxDistM = 1.0,
    Set<String> excludeIds = const {},
  }) {
    final out = <CornerMatch>[];
    for (final c in cands) {
      if (excludeIds.contains(c.id) || !shapeMatches(d, c)) continue;
      final predicted = fit.tileToAr(modelPoint(c));
      final dist = predicted.distanceXzTo(d.posAr);
      if (dist <= maxDistM) out.add(CornerMatch(candidate: c, distanceM: dist));
    }
    out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
    return out;
  }

  /// The model corner a later snap is: the nearest same-shape candidate
  /// within [maxDistM] of where the current fit predicts it, or null. Call
  /// [candidatesNear] first when the UI should offer a choice between two
  /// close candidates.
  CornerCandidate? matchSecond(
    DetectedCorner d,
    AlignmentFit fit,
    List<CornerCandidate> cands, {
    double maxDistM = 1.0,
  }) {
    final near = candidatesNear(d, fit, cands, maxDistM: maxDistM);
    return near.isEmpty ? null : near.first.candidate;
  }

  /// Good second corners after [first], best first: at least
  /// [lockSeparationM] away (so the pair can lock), ideally 5–10 m across the
  /// room, structural, and highly ranked. "Column C-2, 7 m across the room".
  /// Falls back to the farthest candidates when none is far enough.
  List<CornerCandidate> suggestSecond(
    CornerCandidate first,
    List<CornerCandidate> cands,
  ) {
    final others = cands.where((c) => c.id != first.id).toList();
    if (others.isEmpty) return const [];
    final maxRank = others.map((c) => c.rank).fold<double>(0, math.max);

    double distanceScore(double d) {
      if (d < lockSeparationM) return 0;
      if (d <= 10) return math.min(1.0, (d - lockSeparationM) / 4 + 0.25);
      return math.max(0.2, 1 - (d - 10) / 15);
    }

    final far = <(CornerCandidate, double)>[];
    for (final c in others) {
      final d = first.posTile.distanceXzTo(c.posTile);
      if (d < lockSeparationM) continue;
      final rankScore = maxRank > 0 ? c.rank / maxRank : 0.0;
      // From an inside (room) corner, the next one to walk to is another
      // inside corner of the same room; a column's outside corner is usually
      // outside the room or behind furniture (first device run: "Column · SE
      // corner, 5.4 m away" was suggested from inside a bedroom).
      final sameRoom = first.kind == 'inside' && c.kind == 'inside';
      final score = 0.45 * distanceScore(d) +
          0.35 * rankScore +
          (c.structural ? 0.2 : 0.0) +
          (sameRoom ? 0.5 : 0.0);
      far.add((c, score));
    }
    if (far.isEmpty) {
      others.sort((a, b) => first.posTile
          .distanceXzTo(b.posTile)
          .compareTo(first.posTile.distanceXzTo(a.posTile)));
      return others;
    }
    far.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (c, _) in far) c];
  }

  /// Corners to offer for corner A. With a known room ([spaceName], from a
  /// work order or an asset) only that room's corners — matched on the
  /// label the build writes ("Plant Room B · column C-2") — otherwise every
  /// candidate. Best-ranked first; structure breaks ties.
  List<CornerCandidate> rankForRoom(
    List<CornerCandidate> cands, {
    String? spaceName,
  }) {
    var pool = cands;
    final key = spaceName?.trim().toLowerCase();
    if (key != null && key.isNotEmpty) {
      final inRoom =
          cands.where((c) => c.label.toLowerCase().contains(key)).toList();
      if (inRoom.isNotEmpty) pool = inRoom;
    }
    final sorted = List<CornerCandidate>.of(pool);
    sorted.sort((a, b) {
      final byRank = b.rank.compareTo(a.rank);
      if (byRank != 0) return byRank;
      if (a.structural != b.structural) return a.structural ? -1 : 1;
      return a.label.compareTo(b.label);
    });
    return sorted;
  }
}
