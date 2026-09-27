import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/alignment_estimator.dart';
import 'package:technician_portal/core/ar/baseline_heading.dart';
import 'package:technician_portal/core/ar/vec.dart';

/// The model: an inside corner at (2, 0, 3) whose faces look +z and +x, so
/// its walls run along +x (wall with face +z) and +z (wall with face +x).
/// The AR world is the model turned by [_truthYawDeg] and moved.
const _truthYawDeg = 40.0;
final _truth = Mat4.fromYawTranslation(degToRad(_truthYawDeg), const Vec3(0.7, -1.4, -2.1));
const _cornerTile = Vec3(2, 0, 3);

/// A floor-tap corner whose borrowed wall was [errDeg] off.
CornerObs _roughCorner({double errDeg = 6, String method = 'floorTap', Vec3 posErr = Vec3.zero}) {
  final seenYaw = degToRad(_truthYawDeg + errDeg);
  return CornerObs(
    id: 'A',
    aAr: _truth.transformPoint(_cornerTile) + posErr,
    bTile: _cornerTile,
    sigmaM: ArSigma.forCorner(method),
    faceAAr: rotateXz(const Vec2(0, 1), seenYaw),
    faceBAr: rotateXz(const Vec2(1, 0), seenYaw),
    faceATile: const Vec2(0, 1),
    faceBTile: const Vec2(1, 0),
    method: method,
  );
}

void main() {
  const baseline = BaselineHeading();
  const estimator = AlignmentEstimator();

  test('a floor-tap corner 6° off: a wall-base tap 3.5 m along the wall fixes the heading', () {
    final rough = _roughCorner();
    expect(estimator.fit([rough]).yawDeg, closeTo(46, 1e-9), reason: 'the rough heading');
    // Where the +x wall meets the floor, 3.5 m from the corner, with 2 cm of tap error.
    final far = _truth.transformPoint(_cornerTile + const Vec3(3.5, 0, 0)) + const Vec3(0.01, 0, -0.01);
    final r = baseline.refine(rough, far);
    expect(r.ok, isTrue);
    expect(r.lengthM, closeTo(3.5, 0.02));
    expect(r.correctionDeg, closeTo(-6, 0.5));
    final fit = estimator.fit([r.corner!]);
    expect(fit.yawDeg, closeTo(_truthYawDeg, 0.5));
    // The far end now lands within a couple of cm, not 37 cm (6° at 3.5 m).
    expect(fit.tileToAr(_cornerTile + const Vec3(3.5, 0, 0)).distanceXzTo(far), lessThan(0.03));
    expect(fit.quality, AlignmentQuality.placed, reason: 'still one reference: never green');
    expect(r.corner!.baselineM, closeTo(3.5, 0.02));
    expect(r.corner!.roughHeading, isFalse);
    expect(r.corner!.id, 'A');
    expect(r.corner!.method, 'floorTap');
  });

  test('works along the other wall too (+z), and for a depthTaps corner', () {
    final rough = _roughCorner(errDeg: -4, method: 'depthTaps');
    expect(rough.roughHeading, isTrue);
    final far = _truth.transformPoint(_cornerTile + const Vec3(0, 0, 2.5));
    final r = baseline.refine(rough, far);
    expect(r.ok, isTrue);
    expect(estimator.fit([r.corner!]).yawDeg, closeTo(_truthYawDeg, 1e-6));
  });

  test('a point on the wall face (any height) counts: only x/z are used', () {
    final rough = _roughCorner();
    final far = _truth.transformPoint(_cornerTile + const Vec3(2.2, 1.6, 0));
    final r = baseline.refine(rough, far);
    expect(estimator.fit([r.corner!]).yawDeg, closeTo(_truthYawDeg, 1e-6));
  });

  test('too close to the corner: refused', () {
    final r = baseline.refine(_roughCorner(), _truth.transformPoint(_cornerTile + const Vec3(1.0, 0, 0)));
    expect(r.ok, isFalse);
    expect(r.rejected, BaselineRejection.tooShort);
    expect(r.lengthM, closeTo(1.0, 1e-9));
  });

  test('not along either wall (across the room): refused', () {
    final r = baseline.refine(_roughCorner(), _truth.transformPoint(_cornerTile + const Vec3(3, 0, 3)));
    expect(r.rejected, BaselineRejection.notAlongWall);
  });

  test('anchor refinements keep the baseline heading', () {
    final r = baseline.refine(_roughCorner(), _truth.transformPoint(_cornerTile + const Vec3(3, 0, 0)));
    final moved = r.corner!.withAr(r.corner!.aAr + const Vec3(0.01, 0, 0));
    expect(moved.baselineM, r.corner!.baselineM);
    expect(moved.faceAAr, r.corner!.faceAAr);
    expect(moved.withDistanceSince(3).baselineM, r.corner!.baselineM);
  });
}
