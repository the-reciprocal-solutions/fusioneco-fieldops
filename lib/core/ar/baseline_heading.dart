import 'dart:math' as math;

import 'alignment_estimator.dart';
import 'vec.dart';

/// Long-baseline heading (the "second point far away" step after a rough
/// corner). A `floorTap` corner takes its heading from one small vertical
/// surface near the pin, and a `depthTaps` corner from walls fitted over
/// half a metre or so: a few degrees of error, and 5° is 26 cm at 3 m.
///
/// A second point 2–5 m away **along one of the corner's two walls** (a tap
/// where that wall meets the floor, or anywhere on the wall's face) fixes the
/// heading from positions instead: the direction corner → point is the
/// wall's direction in the model. 3 cm of error at each end over 3 m is
/// about 1°. The corner's own faces decide which wall (and which way along
/// it) the point is on; they only need to be within [maxAngleDeg].
///
/// It refines the corner rather than adding an observation: a point made to
/// lie on the modelled wall can't disagree with the corner, so it must never
/// count as the second, independent reference that turns the badge green.
/// Pure; `test/ar_baseline_heading_test.dart`.
enum BaselineRejection {
  /// Closer than [BaselineHeading.minLengthM] to the corner.
  tooShort,

  /// Not along either wall of the corner (more than
  /// [BaselineHeading.maxAngleDeg] off both).
  notAlongWall,
}

class BaselineResult {
  const BaselineResult._({this.corner, this.rejected, required this.lengthM, this.correctionRad = 0});

  /// The corner with its faces turned to the baseline's heading.
  final CornerObs? corner;
  final BaselineRejection? rejected;

  /// Horizontal corner → point distance.
  final double lengthM;

  /// How far the heading moved from the corner's own faces (signed, radians).
  final double correctionRad;

  bool get ok => corner != null;
  double get correctionDeg => radToDeg(correctionRad);
}

class BaselineHeading {
  const BaselineHeading({this.minLengthM = 1.5, this.maxAngleDeg = 25});

  /// The UI asks for 2–5 m; anything from 1.5 m still beats a rough face.
  final double minLengthM;
  final double maxAngleDeg;

  /// [pointAr] is the far point in the AR world (its height is ignored).
  BaselineResult refine(CornerObs corner, Vec3 pointAr) {
    final d = pointAr.xz - corner.aAr.xz;
    final length = d.length;
    if (length < minLengthM) {
      return BaselineResult._(rejected: BaselineRejection.tooShort, lengthM: length);
    }
    final yaw0 = _yawFromFaces(corner);

    // Every way a wall of this corner can run from it, in the model.
    final tangents = <Vec2>[
      for (final n in [corner.faceATile, corner.faceBTile]) ...[
        Vec2(-n.y, n.x).normalized,
        Vec2(n.y, -n.x).normalized,
      ],
    ];
    Vec2? best;
    var bestOff = double.infinity;
    for (final t in tangents) {
      final expected = rotateXz(t, yaw0);
      final off = wrapAngle(headingOf(d) - headingOf(expected)).abs();
      if (off < bestOff) {
        bestOff = off;
        best = t;
      }
    }
    if (best == null || bestOff > degToRad(maxAngleDeg)) {
      return BaselineResult._(rejected: BaselineRejection.notAlongWall, lengthM: length);
    }
    final yaw = headingOf(d) - headingOf(best);
    final refined = CornerObs(
      id: corner.id,
      aAr: corner.aAr,
      bTile: corner.bTile,
      sigmaM: corner.sigmaM,
      distanceSinceM: corner.distanceSinceM,
      faceAAr: rotateXz(corner.faceATile, yaw),
      faceBAr: rotateXz(corner.faceBTile, yaw),
      faceATile: corner.faceATile,
      faceBTile: corner.faceBTile,
      method: corner.method,
      baselineM: length,
    );
    return BaselineResult._(corner: refined, lengthM: length, correctionRad: wrapAngle(yaw - yaw0));
  }

  /// The heading the corner's own (paired) faces imply: the circular mean of
  /// the two faces' angles, as the estimator takes it.
  static double _yawFromFaces(CornerObs c) {
    final ya = headingOf(c.faceAAr) - headingOf(c.faceATile);
    final yb = headingOf(c.faceBAr) - headingOf(c.faceBTile);
    return math.atan2(math.sin(ya) + math.sin(yb), math.cos(ya) + math.cos(yb));
  }
}
