import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/alignment_estimator.dart';
import 'package:technician_portal/core/ar/vec.dart';

const _estimator = AlignmentEstimator();

/// The contract's golden truth: yaw 30°, t = (1, 0.2, −3).
final _truth = Mat4.fromYawTranslation(degToRad(30), const Vec3(1, 0.2, -3));
const _normalTile = Vec3(1, 0, 0);
final _normalAr = _truth.transformDir(_normalTile);

MarkerObs _marker(
  String id,
  Vec3 bTile, {
  Vec3? offset,
  double sigma = ArSigma.feature,
  double distanceSince = 0,
}) =>
    MarkerObs(
      id: id,
      aAr: _truth.transformPoint(bTile) + (offset ?? Vec3.zero),
      bTile: bTile,
      sigmaM: sigma,
      distanceSinceM: distanceSince,
      normalAr: _normalAr,
      normalTile: _normalTile,
    );

void main() {
  group('CONTRACT C2 golden fit', () {
    test('θ = 30°, t = (1, 0.2, −3) within 1e-5, residuals ≈ 0, locked', () {
      final fit = _estimator.fit(const [
        MarkerObs(
          id: 'b1',
          aAr: Vec3(1, 0.2, -3),
          bTile: Vec3(0, 0, 0),
          sigmaM: ArSigma.feature,
          normalAr: Vec3(1, 0, 0),
          normalTile: Vec3(1, 0, 0),
        ),
        MarkerObs(
          id: 'b2',
          aAr: Vec3(5.330127, 0.2, -5.5),
          bTile: Vec3(5, 0, 0),
          sigmaM: ArSigma.feature,
          normalAr: Vec3(1, 0, 0),
          normalTile: Vec3(1, 0, 0),
        ),
        MarkerObs(
          id: 'b3',
          aAr: Vec3(3, 1.7, 0.464102),
          bTile: Vec3(0, 1.5, 4),
          sigmaM: ArSigma.feature,
          normalAr: Vec3(1, 0, 0),
          normalTile: Vec3(1, 0, 0),
        ),
      ]);
      expect(fit.yawDeg, closeTo(30, 1e-5));
      expect(fit.t.x, closeTo(1, 1e-5));
      expect(fit.t.y, closeTo(0.2, 1e-5));
      expect(fit.t.z, closeTo(-3, 1e-5));
      expect(fit.maxResidualM, lessThan(1e-5));
      expect(fit.quality, AlignmentQuality.locked);
      expect(fit.method, 'positions');
      expect(fit.observationCount, 3);
      expect(fit.outliers, isEmpty);
    });

    test('arFromTile maps the model onto the observations', () {
      final fit = _estimator.fit([
        _marker('a', const Vec3(0, 1.5, 0)),
        _marker('b', const Vec3(6, 1.5, 0)),
      ]);
      final p = fit.tileToAr(const Vec3(3, 1, 2));
      final q = _truth.transformPoint(const Vec3(3, 1, 2));
      expect(p.distanceTo(q), lessThan(1e-9));
      expect(fit.arToTile(q).distanceTo(const Vec3(3, 1, 2)), lessThan(1e-9));
    });
  });

  group('quality states', () {
    test('none: no observations', () {
      final fit = _estimator.fit(const []);
      expect(fit.quality, AlignmentQuality.none);
      expect(fit.isPlaced, isFalse);
      expect(fit.arFromTile.closeTo(Mat4.identity()), isTrue);
    });

    test('placed: one board — heading from its wall normal', () {
      final fit = _estimator.fit([_marker('only', const Vec3(2, 1.5, 1))]);
      expect(fit.quality, AlignmentQuality.placed);
      expect(fit.method, 'directions');
      expect(fit.yawDeg, closeTo(30, 1e-9));
      expect(fit.t.distanceTo(const Vec3(1, 0.2, -3)), lessThan(1e-9));
    });

    test('placed: two boards under 1.5 m apart stay amber (directions)', () {
      final fit = _estimator.fit([
        _marker('p', const Vec3(0, 1.5, 0)),
        _marker('q', const Vec3(1, 1.5, 0)),
      ]);
      expect(fit.spreadM, closeTo(0.5, 1e-12));
      expect(fit.quality, AlignmentQuality.placed);
      expect(fit.method, 'directions');
      expect(fit.yawDeg, closeTo(30, 1e-9));
    });

    test('locked: two boards 5 m apart that agree', () {
      final fit = _estimator.fit([
        _marker('a', const Vec3(0, 1.5, 0)),
        _marker('b', const Vec3(5, 1.5, 0)),
      ]);
      expect(fit.spreadM, closeTo(2.5, 1e-12));
      expect(fit.quality, AlignmentQuality.locked);
      expect(fit.method, 'positions');
    });

    test('siteMismatch: two boards 12 cm apart from their modelled spacing', () {
      final along = _truth.transformDir(const Vec3(1, 0, 0));
      final fit = _estimator.fit([
        _marker('a', const Vec3(0, 1.5, 0)),
        _marker('b', const Vec3(5, 1.5, 0), offset: along * 0.12),
      ]);
      expect(fit.residualsM['a'], closeTo(0.06, 1e-9));
      expect(fit.residualsM['b'], closeTo(0.06, 1e-9));
      expect(fit.outliers, isEmpty, reason: 'with two, nobody can tell which one moved');
      expect(fit.quality, AlignmentQuality.siteMismatch);
    });

    test('manual: a nudge is never evidence, whatever the residuals', () {
      final fit = _estimator.fit(
        [_marker('a', const Vec3(0, 1.5, 0)), _marker('b', const Vec3(5, 1.5, 0))],
        nudgeAr: const Vec3(0.015, 0, 0),
      );
      expect(fit.quality, AlignmentQuality.manual);
      expect(fit.nudgeM, closeTo(0.015, 1e-12));
      expect(fit.t.x, closeTo(1.015, 1e-9));
      expect(_estimator.fit([_marker('a', const Vec3(0, 1.5, 0))], manual: true).quality,
          AlignmentQuality.manual);
    });

    test('drifting: set by the runtime check, kept until the next refit', () {
      final fit = _estimator.fit([
        _marker('a', const Vec3(0, 1.5, 0)),
        _marker('b', const Vec3(5, 1.5, 0)),
      ]);
      final drifting = fit.withQuality(AlignmentQuality.drifting);
      expect(drifting.quality, AlignmentQuality.drifting);
      expect(drifting.arFromTile, fit.arFromTile);
    });
  });

  group('outliers', () {
    test('a board knocked 30 cm is dropped, reported, and the rest lock', () {
      final fit = _estimator.fit([
        _marker('m1', const Vec3(0, 1.5, 0)),
        _marker('m2', const Vec3(6, 1.5, 0)),
        _marker('m3', const Vec3(6, 1.5, 5)),
        _marker('m4', const Vec3(0, 1.5, 5), offset: const Vec3(0.30, 0, 0)),
      ]);
      expect(fit.outliers, ['m4']);
      expect(fit.observationCount, 3);
      expect(fit.quality, AlignmentQuality.locked);
      expect(fit.yawDeg, closeTo(30, 1e-9));
      expect(fit.residualsM['m4'], closeTo(0.30, 1e-9));
      expect(fit.maxResidualM, lessThan(1e-9));
    });

    test('a residual inside max(3σ, 5 cm) is not an outlier', () {
      final fit = _estimator.fit([
        _marker('m1', const Vec3(0, 1.5, 0)),
        _marker('m2', const Vec3(6, 1.5, 0)),
        _marker('m3', const Vec3(6, 1.5, 5), offset: const Vec3(0, 0.02, 0)),
      ]);
      expect(fit.outliers, isEmpty);
    });
  });

  group('weights', () {
    test('σ by class, PnP doubled, corners by method', () {
      expect(ArSigma.forMarker('surveyed', 'lidar'), 0.005);
      expect(ArSigma.forMarker('feature', 'plane'), 0.02);
      expect(ArSigma.forMarker('derived', 'depth'), 0.03);
      expect(ArSigma.forMarker('feature', 'pnp'), 0.04);
      expect(ArSigma.forCorner('lidar'), 0.02);
      expect(ArSigma.forCorner('planes'), 0.04);
      expect(ArSigma.forCorner('floorTap'), 0.06);
      expect(ArSigma.forCorner('something-new'), 0.06, reason: 'unknown is treated as the weakest');
    });

    test('w = 1 / (σ² + (0.02 · distance)²)', () {
      expect(AlignmentEstimator.weightOf(_marker('a', Vec3.zero)), closeTo(2500, 1e-9));
      expect(AlignmentEstimator.weightOf(_marker('a', Vec3.zero, distanceSince: 1)), closeTo(1250, 1e-9));
    });

    test('an old observation counts for less than a fresh one', () {
      // Two boards at the same model point disagree by 10 cm; the fresh one
      // (0 m walked) should pull the fit much harder than the stale one.
      final fresh = _marker('fresh', const Vec3(0, 1.5, 0));
      final stale = _marker('stale', const Vec3(0, 1.5, 0),
          offset: const Vec3(0.10, 0, 0), distanceSince: 20);
      final fit = _estimator.fit([fresh, stale]);
      expect(fit.residualsM['fresh']!, lessThan(fit.residualsM['stale']!));
      expect(fit.residualsM['fresh']!, lessThan(0.01));
    });
  });

  group('DriftMonitor', () {
    test('trips only after a consistent offset over 3 cm for 2 s', () {
      final monitor = DriftMonitor();
      final t0 = DateTime(2026, 9, 26, 10);
      expect(monitor.add(t0, 0.04), isFalse);
      expect(monitor.add(t0.add(const Duration(milliseconds: 1500)), 0.05), isFalse);
      expect(monitor.add(t0.add(const Duration(seconds: 2)), 0.04), isTrue);
    });

    test('one sample under the threshold starts over', () {
      final monitor = DriftMonitor();
      final t0 = DateTime(2026, 9, 26, 10);
      monitor.add(t0, 0.04);
      monitor.add(t0.add(const Duration(seconds: 1)), 0.01);
      expect(monitor.add(t0.add(const Duration(milliseconds: 2500)), 0.04), isFalse);
    });
  });

  group('nudgeAxis', () {
    test('picks the normal of the wall the camera looks along', () {
      // Looking along +x: the wall with normal ±z is the one we face along.
      final axis = AlignmentEstimator.nudgeAxis(
        cameraForwardAr: const Vec3(1, -0.2, 0.05),
        wallNormalsAr: const [Vec2(1, 0), Vec2(0, 1)],
      )!;
      expect(axis.x.abs(), lessThan(1e-9));
      expect(axis.z.abs(), closeTo(1, 1e-9));
      expect(axis.y, 0);
    });

    test('null with no walls', () {
      expect(
        AlignmentEstimator.nudgeAxis(cameraForwardAr: const Vec3(1, 0, 0), wallNormalsAr: const []),
        isNull,
      );
    });
  });

  test('yaw is recovered for any heading, not just 30°', () {
    for (final deg in [-170.0, -90.0, 0.0, 45.0, 179.0]) {
      final truth = Mat4.fromYawTranslation(degToRad(deg), const Vec3(-4, 1, 7));
      MarkerObs obs(String id, Vec3 b) => MarkerObs(
            id: id,
            aAr: truth.transformPoint(b),
            bTile: b,
            sigmaM: ArSigma.feature,
            normalAr: truth.transformDir(_normalTile),
            normalTile: _normalTile,
          );
      final fit = _estimator.fit([obs('a', const Vec3(0, 1, 0)), obs('b', const Vec3(4, 1, 3))]);
      expect(wrapAngle(fit.yawRad - degToRad(deg)).abs(), lessThan(1e-9), reason: '$deg°');
      expect(fit.quality, AlignmentQuality.locked);
    }
  });

  group('floor-anchored height (P-012)', () {
    test('a board hung 5 cm high no longer lifts the model when the floor is tracked', () {
      // Floor at tile y = 0 → AR y = 0.2 (the truth's tY).
      final fit = _estimator.fit(
        [
          _marker('high', const Vec3(0, 1.5, 0), offset: const Vec3(0, 0.05, 0)),
          _marker('ok', const Vec3(6, 1.5, 0)),
        ],
        floorAr: 0.2,
        floorTileY: 0,
      );
      expect(fit.floorAnchored, isTrue);
      expect(fit.t.y, closeTo(0.2, 1e-9));
      expect(fit.verticalErrorsM['high'], closeTo(0.05, 1e-6));
      // Heights are the floor's job: residuals are horizontal only.
      expect(fit.maxResidualM, lessThan(1e-6));
      expect(fit.quality, AlignmentQuality.locked);
    });

    test('without a floor the same board drags the model up by half its error', () {
      final fit = _estimator.fit([
        _marker('high', const Vec3(0, 1.5, 0), offset: const Vec3(0, 0.05, 0)),
        _marker('ok', const Vec3(6, 1.5, 0)),
      ]);
      expect(fit.floorAnchored, isFalse);
      expect(fit.t.y, closeTo(0.225, 1e-6));
    });
  });

  group('green needs agreement within 2 cm', () {
    test('two far boards that disagree by 7 cm (3.5 cm each) are usable but amber', () {
      final fit = _estimator.fit([
        _marker('a', const Vec3(0, 1.5, 0), offset: const Vec3(0.07, 0, 0)),
        _marker('b', const Vec3(6, 1.5, 0)),
      ]);
      expect(fit.maxResidualM, greaterThan(AlignmentEstimator.greenResidualM));
      expect(fit.maxResidualM, lessThanOrEqualTo(AlignmentEstimator.lockResidualM));
      expect(fit.quality, AlignmentQuality.placed);
    });
  });
}
