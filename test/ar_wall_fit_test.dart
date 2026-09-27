import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/alignment_estimator.dart';
import 'package:technician_portal/core/ar/ar_engine.dart' show ArDepthPoint;
import 'package:technician_portal/core/ar/corner_matcher.dart';
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/core/ar/wall_fit.dart';
import 'package:technician_portal/state/ar_setup_controller.dart';

/// A room corner in the AR world, rotated by [yawDeg]: wall A runs along
/// +x from the corner (its face looks +z, into the room), wall B along +z
/// (its face looks +x). The camera stands inside the room.
class _Room {
  _Room(double yawDeg) : yaw = degToRad(yawDeg);

  final double yaw;
  final Vec3 corner = const Vec3(1.2, -1.4, -2.3);

  Vec2 get faceA => rotateXz(const Vec2(0, 1), yaw);
  Vec2 get faceB => rotateXz(const Vec2(1, 0), yaw);

  /// A point on wall A, [along] metres from the corner, [off] metres off
  /// the wall (depth noise), at height [h] above the floor.
  WallTap onA(double along, double h, [double off = 0]) {
    final p = corner.xz + faceB * along + faceA * off;
    return WallTap(Vec3(p.x, corner.y + h, p.y), Vec3(faceA.x, 0, faceA.y));
  }

  WallTap onB(double along, double h, [double off = 0]) {
    final p = corner.xz + faceA * along + faceB * off;
    return WallTap(Vec3(p.x, corner.y + h, p.y), Vec3(faceB.x, 0, faceB.y));
  }

  Vec3 get camera {
    final p = corner.xz + (faceA + faceB) * 2.0;
    return Vec3(p.x, corner.y + 1.5, p.y);
  }
}

void main() {
  const fitter = WallFitter();

  group('one wall', () {
    test('three clean taps: the wall line, normal toward the camera', () {
      final room = _Room(30);
      final r = fitter.fit([room.onA(0.3, 0.5), room.onA(0.7, 1.4), room.onA(1.1, 0.9)], cameraAr: room.camera);
      expect(r.ok, isTrue);
      final w = r.value!;
      expect(w.normal.distanceTo(room.faceA), lessThan(1e-9));
      expect(w.signedDistance(room.corner.xz).abs(), lessThan(1e-9));
      expect(w.rmsM, lessThan(1e-9));
      expect(w.spanM, closeTo(0.8, 1e-9));
      expect(w.outliers, isEmpty);
    });

    test('the normal flips to face the camera whatever the tap order', () {
      final room = _Room(-70);
      final r = fitter.fit([room.onB(1.0, 0.4), room.onB(0.2, 1.2), room.onB(0.6, 0.8)], cameraAr: room.camera);
      expect(r.value!.normal.distanceTo(room.faceB), lessThan(1e-9));
    });

    test('a tap on a door frame 6 cm proud of the wall is dropped', () {
      final room = _Room(10);
      final taps = [
        room.onA(0.2, 0.5, 0.004),
        room.onA(0.5, 1.2, -0.006),
        room.onA(0.8, 0.8, 0.06), // the door frame
        room.onA(1.1, 1.0, 0.003),
        room.onA(1.4, 0.6, -0.002),
      ];
      final w = fitter.fit(taps, cameraAr: room.camera).value!;
      expect(w.outliers, [2]);
      expect(w.inliers, 4);
      final angle = math.acos(w.normal.dot(room.faceA).clamp(-1.0, 1.0)) * 180 / math.pi;
      expect(angle, lessThan(0.6));
    });

    test('never drops below three taps (two points always fit a line)', () {
      final room = _Room(0);
      final w = fitter.fit([room.onA(0.2, 0.5), room.onA(0.6, 1.0), room.onA(1.0, 0.8, 0.2)], cameraAr: room.camera).value!;
      expect(w.outliers, isEmpty);
      expect(w.inliers, 3);
    });

    test('clustered taps take the direction from the engine normals', () {
      final room = _Room(25);
      final taps = [room.onA(0.50, 0.5, 0.01), room.onA(0.52, 1.0, -0.01), room.onA(0.55, 0.8, 0.012)];
      final w = fitter.fit(taps, cameraAr: room.camera).value!;
      expect(w.fromNormals, isTrue);
      expect(w.normal.distanceTo(room.faceA), lessThan(1e-9));
    });

    test('clustered taps without normals: no direction', () {
      final room = _Room(25);
      final taps = [
        for (final t in [room.onA(0.50, 0.5, 0.01), room.onA(0.52, 1.0, -0.01), room.onA(0.55, 0.8, 0.012)])
          WallTap(t.posAr),
      ];
      expect(fitter.fit(taps, cameraAr: room.camera).failure, WallFitFailure.noDirection);
    });

    test('fewer than three taps', () {
      final room = _Room(0);
      expect(fitter.fit([room.onA(0.2, 1), room.onA(0.9, 1)]).failure, WallFitFailure.tooFewTaps);
    });

    test('a floor tap is recognised by its normal', () {
      expect(WallFitter.looksLikeFloor(const Vec3(0.05, 0.99, 0.02)), isTrue);
      expect(WallFitter.looksLikeFloor(const Vec3(0.9, 0.1, 0.3)), isFalse);
      expect(WallFitter.looksLikeFloor(null), isFalse);
    });
  });

  group('corner from two walls', () {
    for (final yaw in [0.0, 37.0, -115.0]) {
      test('inside 90° corner on the floor (yaw $yaw°)', () {
        final room = _Room(yaw);
        final a = [room.onA(0.3, 0.6, 0.005), room.onA(0.7, 1.3, -0.004), room.onA(1.0, 0.9, 0.003)];
        final b = [room.onB(0.4, 1.1, -0.003), room.onB(0.8, 0.5, 0.004), room.onB(1.2, 1.4, -0.002)];
        final r = fitter.corner(a, b, floorY: room.corner.y, cameraAr: room.camera);
        expect(r.ok, isTrue);
        final c = r.value!;
        expect(c.posAr.distanceTo(room.corner), lessThan(0.01));
        expect(c.posAr.y, room.corner.y);
        expect(c.angleDeg, closeTo(90, 1));
        expect(c.kind, 'inside');
        expect(c.faceAAr.cross(c.faceBAr), greaterThanOrEqualTo(0), reason: 'native face order');
        final d = c.toDetected();
        expect(d.method, 'depthTaps');
        expect(ArSigma.forCorner(d.method), ArSigma.cornerDepthTaps);
      });
    }

    test('the corner pairs with a model corner like a native snap', () {
      // Model: corner at the origin, faces +z and +x; seen rotated by 37°.
      final room = _Room(37);
      final a = [room.onA(0.3, 0.6), room.onA(0.7, 1.3), room.onA(1.0, 0.9)];
      final b = [room.onB(0.4, 1.1), room.onB(0.8, 0.5), room.onB(1.2, 1.4)];
      final d = fitter.corner(a, b, floorY: room.corner.y, cameraAr: room.camera).value!.toDetected();
      const candidate = CornerCandidate(
        id: 'c1',
        posTile: Vec3.zero,
        faceA: Vec2(0, 1),
        faceB: Vec2(1, 0),
        angleDeg: 90,
        kind: 'inside',
      );
      final obs = const CornerMatcher().firstCorner(d, candidate, cameraAr: room.camera);
      final fit = const AlignmentEstimator().fit([obs]);
      expect(fit.yawDeg, closeTo(37, 0.01));
      expect(fit.tileToAr(Vec3.zero).distanceTo(room.corner), lessThan(1e-6));
    });

    test('an outside corner (a column) is told apart', () {
      // Faces point out of the material toward the camera; walls run away
      // from the corner on the far side of each other.
      const corner = Vec3(0, -1.4, 0);
      const fa = Vec2(0, 1);
      const fb = Vec2(1, 0);
      WallTap on(Vec2 face, Vec2 along, double s, double h) {
        final p = corner.xz + along * s;
        return WallTap(Vec3(p.x, corner.y + h, p.y), Vec3(face.x, 0, face.y));
      }

      final a = [on(fa, const Vec2(-1, 0), 0.1, 0.5), on(fa, const Vec2(-1, 0), 0.25, 1.0), on(fa, const Vec2(-1, 0), 0.4, 0.8)];
      final b = [on(fb, const Vec2(0, -1), 0.1, 0.6), on(fb, const Vec2(0, -1), 0.25, 1.2), on(fb, const Vec2(0, -1), 0.4, 0.9)];
      final c = fitter.corner(a, b, floorY: corner.y, cameraAr: const Vec3(1.5, 0, 1.5)).value!;
      expect(c.kind, 'outside');
      expect(c.posAr.distanceTo(corner), lessThan(1e-9));
      expect(c.angleDeg, closeTo(90, 1e-6));
    });

    test('two taps sets on the same wall: parallel, refused', () {
      final room = _Room(12);
      final a = [room.onA(0.2, 0.6), room.onA(0.6, 1.3), room.onA(1.0, 0.9)];
      final b = [room.onA(1.4, 0.6), room.onA(1.8, 1.3), room.onA(2.2, 0.9)];
      expect(fitter.corner(a, b, floorY: room.corner.y, cameraAr: room.camera).failure, WallFitFailure.parallel);
    });

    test('walls whose corner is far from every tap: refused', () {
      final room = _Room(0);
      final a = [room.onA(3.0, 0.6), room.onA(3.4, 1.3), room.onA(3.8, 0.9)];
      final b = [room.onB(0.4, 1.1), room.onB(0.8, 0.5), room.onB(1.2, 1.4)];
      expect(fitter.corner(a, b, floorY: room.corner.y, cameraAr: room.camera).failure, WallFitFailure.tooFar);
    });
  });

  group('which measured points are wall taps (setup)', () {
    String? reject(ArDepthPoint? p, [double? floorY = -1.4]) => ArSetupController.wallTapRejection(p, floorY);

    test('a confident wall point is taken', () {
      expect(reject(const ArDepthPoint(posAr: Vec3(1, -0.6, -2), normalAr: Vec3(0, 0.05, 1), confidence: 0.8)), isNull);
      expect(reject(const ArDepthPoint(posAr: Vec3(1, -0.6, -2), confidence: 0.8)), isNull, reason: 'no normal is fine');
    });

    test('nothing measured, low confidence, or the floor are refused with a reason', () {
      expect(reject(null), 'ar.walls.no_depth');
      expect(reject(const ArDepthPoint(posAr: Vec3(1, -0.6, -2), confidence: 0.1)), 'ar.walls.low_confidence');
      expect(reject(const ArDepthPoint(posAr: Vec3(1, -0.6, -2), normalAr: Vec3(0, 1, 0), confidence: 0.9)), 'ar.walls.floor');
      expect(reject(const ArDepthPoint(posAr: Vec3(1, -1.39, -2), confidence: 0.9)), 'ar.walls.floor');
      expect(reject(const ArDepthPoint(posAr: Vec3(1, -1.39, -2), confidence: 0.9), null), isNull, reason: 'no floor known yet');
    });
  });
}
