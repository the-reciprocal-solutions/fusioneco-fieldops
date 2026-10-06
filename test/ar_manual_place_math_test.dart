import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/alignment_estimator.dart';
import 'package:technician_portal/core/ar/ar_engine.dart';
import 'package:technician_portal/core/ar/manual_place_math.dart';
import 'package:technician_portal/core/ar/vec.dart';

/// "Place by hand" maths (manual_place_math.dart): gesture → pose, the
/// snaps, undo/redo, the true-size rules and the fit it hands over.

const _eps = 1e-6;

Matcher _near(double v, [double eps = 1e-6]) => closeTo(v, eps);

void _expectVec2(Vec2 a, Vec2 b, [double eps = 1e-6]) {
  expect(a.x, closeTo(b.x, eps), reason: '$a vs $b');
  expect(a.y, closeTo(b.y, eps), reason: '$a vs $b');
}

ArPlane _wall(String id, Vec2 a, Vec2 b, Vec2 normal) => ArPlane(
      id: id,
      kind: 'wall',
      centerAr: Vec3((a.x + b.x) / 2, 1.2, (a.y + b.y) / 2),
      normalAr: Vec3(normal.x, 0, normal.y),
      segment: (a, b),
      widthM: a.distanceTo(b),
      heightM: 2.4,
    );

/// A 3 × 5 m room, corners at the origin and (3, 5) in the tile frame.
ModelFootprint _room() => ModelFootprint.build(
      floorTileY: 0,
      room: const [Vec2(0, 0), Vec2(3, 0), Vec2(3, 5), Vec2(0, 5)],
      walls: const [
        [Vec2(0, 0), Vec2(3, 0), Vec2(3, 5), Vec2(0, 5), Vec2(0, 0)],
      ],
      thicknesses: const [0.2],
    );

void main() {
  group('ManualPose', () {
    test('true size + no turn = pure translation of the pivot', () {
      const pose = ManualPose(pos: Vec2(2, -1), floorY: -1.4);
      final m = pose.arFromTile(const Vec3(1.5, 0, 2.5));
      final p = m.transformPoint(const Vec3(1.5, 0, 2.5));
      expect(p.x, _near(2));
      expect(p.y, _near(-1.4));
      expect(p.z, _near(-1));
      expect(m.isRigid, isTrue);
      expect(pose.isTrueSize, isTrue);
    });

    test('scale is about the pivot, yaw follows CONTRACT C2, height lifts', () {
      final pose = ManualPose(pos: const Vec2(0, 0), yawRad: math.pi / 2, scale: 2, heightM: 0.1);
      const pivot = Vec3(1, 0, 1);
      final m = pose.arFromTile(pivot);
      // One metre along tile +X from the pivot, doubled, turned 90°: +X → −Z.
      final p = m.transformPoint(const Vec3(2, 0, 1));
      expect(p.x, _near(0));
      expect(p.z, _near(-2));
      expect(p.y, _near(0.1));
      expect(m.isRigid, isFalse);
      // Same rotation as the 4-DoF fit uses.
      final r = Mat4.fromYawTranslation(math.pi / 2, Vec3.zero).transformDir(const Vec3(1, 0, 0));
      expect(p.xz.normalized.x, _near(r.x));
      expect(p.xz.normalized.y, _near(r.z));
    });

    test('the general inverse round-trips a scaled, stretched pose', () {
      const pose = ManualPose(pos: Vec2(3, 4), floorY: -1.2, yawRad: 0.7, scale: 1.3, stretchX: 1.1, stretchZ: 0.9, heightM: 0.05);
      final m = pose.arFromTile(const Vec3(2, 0.1, -1));
      final inv = m.inverse();
      const q = Vec3(-0.4, 1.7, 2.2);
      final back = inv.transformPoint(m.transformPoint(q));
      expect(back.x, _near(q.x, 1e-9));
      expect(back.y, _near(q.y, 1e-9));
      expect(back.z, _near(q.z, 1e-9));
    });

    test('size JSON keeps only the size, clamped', () {
      const pose = ManualPose(pos: Vec2(9, 9), scale: 1.12, stretchX: 1.05, heightM: 0.02);
      final size = ManualPose.sizeFromJson(pose.sizeJson())!;
      expect(size.scale, 1.12);
      expect(size.stretchX, 1.05);
      expect(size.heightM, 0.02);
      expect(ManualPose.sizeFromJson({'scale': 9})!.scale, ManualLimits.maxScale);
      expect(ManualPose.sizeFromJson('nonsense'), isNull);
    });
  });

  group('gestures', () {
    test('floor hit: straight down, away from the floor, and far rays clamped', () {
      const down = ArRay(originAr: Vec3(1, 1.5, 2), dirAr: Vec3(0, -1, 0));
      final hit = ManualGestures.floorHit(down, 0)!;
      expect(hit.x, _near(1));
      expect(hit.y, _near(0));
      expect(hit.z, _near(2));
      expect(ManualGestures.floorHit(const ArRay(originAr: Vec3(0, 1.5, 0), dirAr: Vec3(0, 1, 0)), 0), isNull);
      // Nearly level: would land 150 m away; clamped to the reach.
      final far = ManualGestures.floorHit(ArRay(originAr: const Vec3(0, 1.5, 0), dirAr: const Vec3(0, -0.01, -1).normalized), 0)!;
      expect(far.xz.length, _near(ManualLimits.maxReachM, 1e-6));
    });

    test('drag on the plane follows the finger exactly; fine mode is a quarter', () {
      const start = ManualPose(pos: Vec2(1, 1));
      final p = ManualGestures.dragged(start, const Vec3(0, 0, 0), const Vec3(0.4, 0, -0.2));
      _expectVec2(p.pos, const Vec2(1.4, 0.8));
      final f = ManualGestures.dragged(start, const Vec3(0, 0, 0), const Vec3(0.4, 0, -0.2), fine: true);
      _expectVec2(f.pos, const Vec2(1.1, 0.95));
    });

    test('twist: clockwise on screen is a negative yaw; fine mode slows it', () {
      expect(ManualGestures.twisted(0, 0.2), _near(-0.2));
      expect(ManualGestures.twisted(0.5, -0.4, fine: true), _near(0.6));
      expect(ManualGestures.twisted(math.pi - 0.1, -0.3), _near(-math.pi + 0.2));
    });

    test('pinch clamps to 50–200 % and sticks at 100 %', () {
      expect(ManualGestures.pinched(1, 5), ManualLimits.maxScale);
      expect(ManualGestures.pinched(1, 0.1), ManualLimits.minScale);
      expect(ManualGestures.pinched(1, 1.02), 1.0, reason: 'inside the ±3 % detent');
      expect(ManualGestures.pinched(1.2, 0.85), 1.0, reason: '102 % snaps to true size');
      expect(ManualGestures.pinched(1, 1.12), _near(1.12));
      expect(ManualGestures.pinched(1, 2, fine: true), _near(math.pow(2, 0.25).toDouble()));
      expect(ManualGestures.pinched(1, 0), 1.0, reason: 'a zero scale from the recogniser is ignored');
    });

    test('height drag: up raises, clamped to ±1 m', () {
      expect(ManualGestures.heightDragged(0, -50), _near(0.1));
      expect(ManualGestures.heightDragged(0, 10000), -ManualLimits.maxHeightM);
    });

    test('two fingers decide once: twist/pinch vs straight vertical drag', () {
      expect(TwoFingerClassifier.classify(rotationRad: 0, scale: 1, dxPx: 2, dyPx: 5), TwoFingerMode.undecided);
      expect(TwoFingerClassifier.classify(rotationRad: 0.2, scale: 1, dxPx: 0, dyPx: 40), TwoFingerMode.transform);
      expect(TwoFingerClassifier.classify(rotationRad: 0, scale: 1.1, dxPx: 0, dyPx: 0), TwoFingerMode.transform);
      expect(TwoFingerClassifier.classify(rotationRad: 0, scale: 1, dxPx: 5, dyPx: -40), TwoFingerMode.height);
      expect(TwoFingerClassifier.classify(rotationRad: 0, scale: 1, dxPx: 40, dyPx: 30), TwoFingerMode.undecided);
    });

    test('nudge pad moves relative to the view: right is the camera’s right', () {
      const p = ManualPose(pos: Vec2(0, 0));
      // Looking down −Z: right is +X, away is −Z.
      _expectVec2(ManualGestures.nudged(p, rightM: 0.01, cameraForwardAr: const Vec3(0, 0, -1)).pos, const Vec2(0.01, 0));
      _expectVec2(ManualGestures.nudged(p, awayM: 0.01, cameraForwardAr: const Vec3(0, 0, -1)).pos, const Vec2(0, -0.01));
      // Looking down +X: right is +Z.
      _expectVec2(ManualGestures.nudged(p, rightM: 0.01, cameraForwardAr: const Vec3(1, -0.5, 0)).pos, const Vec2(0, 0.01));
      expect(ManualGestures.nudged(p, turnDeg: 1).yawRad, _near(-degToRad(1)));
      expect(ManualGestures.nudged(p, upM: 0.01).heightM, _near(0.01));
    });

    test('keepFixed pinches about a pinned corner instead of the centre', () {
      const pivot = Vec3(1.5, 0, 2.5);
      const corner = Vec3(0, 0, 0);
      const before = ManualPose(pos: Vec2(5, 5));
      final grown = before.copyWith(scale: 1.4, yawRad: 0.2);
      final kept = ManualGestures.keepFixed(before, grown, corner, pivot);
      final a = before.arFromTile(pivot).transformPoint(corner);
      final b = kept.arFromTile(pivot).transformPoint(corner);
      _expectVec2(a.xz, b.xz, 1e-9);
      expect(kept.scale, 1.4);
    });

    test('load pose: 1.5 m ahead on the floor, plan-up facing the user’s way', () {
      final p = ManualGestures.initialPose(cameraAr: const Vec3(0, 1.5, 0), forwardAr: const Vec3(0, -0.6, -1), floorY: 0.02);
      _expectVec2(p.pos, const Vec2(0, -1.5));
      expect(p.floorY, 0.02);
      expect(p.yawRad, _near(0));
      expect(p.isTrueSize, isTrue);
      // No floor yet: a standing phone's height below the camera.
      final q = ManualGestures.initialPose(cameraAr: const Vec3(0, 1.5, 0), forwardAr: const Vec3(1, 0, 0));
      expect(q.floorY, _near(1.5 - ManualLimits.eyeHeightM));
      _expectVec2(q.pos, const Vec2(1.5, 0));
      // Plan-up (−Z) turned onto +X.
      final up = Mat4.fromYawTranslation(q.yawRad, Vec3.zero).transformDir(const Vec3(0, 0, -1));
      expect(up.x, _near(1));
    });

    test('load pose squares itself to a detected wall', () {
      // A wall whose normal is 10° off the axes; the model's walls are on the axes.
      final n = rotateXz(const Vec2(0, 1), degToRad(10));
      final w = _wall('w', const Vec2(-2, -3), const Vec2(2, -3), n);
      final p = ManualGestures.initialPose(cameraAr: const Vec3(0, 1.5, 0), forwardAr: const Vec3(0, 0, -1), walls: [w]);
      expect(ManualGestures.quarterDiff(p.yawRad, degToRad(10)), _near(0, 1e-9));
    });
  });

  group('soft snap to walls', () {
    test('within 4° of a wall-aligned heading clicks onto it, at any quarter turn', () {
      final aligned = [degToRad(30)];
      final s1 = ManualGestures.softSnapYaw(degToRad(33), aligned);
      expect(s1.snapped, isTrue);
      expect(s1.yaw, _near(degToRad(30), 1e-9));
      final s2 = ManualGestures.softSnapYaw(degToRad(30 + 90 - 3), aligned);
      expect(s2.snapped, isTrue);
      expect(s2.yaw, _near(degToRad(120), 1e-9));
      final s3 = ManualGestures.softSnapYaw(degToRad(37), aligned);
      expect(s3.snapped, isFalse);
      expect(s3.yaw, _near(degToRad(37)));
    });

    test('aligned headings come from the wall normals and the model’s own main direction', () {
      final w = _wall('w', const Vec2(0, 0), const Vec2(1, 0), rotateXz(const Vec2(0, 1), degToRad(20)));
      final yaws = ManualGestures.wallAlignedYaws(degToRad(5), [w]);
      expect(yaws, hasLength(1));
      expect(ManualGestures.quarterDiff(yaws.single, degToRad(15)), _near(0, 1e-9));
    });

    test('a footprint’s main heading is its walls’ direction modulo 90°', () {
      final fp = ModelFootprint.build(
        floorTileY: 0,
        walls: [
          [const Vec2(0, 0), rotateXz(const Vec2(4, 0), degToRad(12))],
        ],
      );
      expect(ManualGestures.quarterDiff(fp.mainHeadingRad, headingOf(rotateXz(const Vec2(1, 0), degToRad(12)))), _near(0, 1e-9));
    });
  });

  group('snap to wall', () {
    test('the nearest model face turns parallel to the detected wall and lands on it', () {
      final fp = _room();
      // The real north wall: z = −3.2 in AR, its normal facing into the
      // room (+Z), turned 6° from the model's.
      final n = rotateXz(const Vec2(0, 1), degToRad(6));
      final w = ArPlane(id: 'north', kind: 'wall', centerAr: const Vec3(0, 1.2, -3.2), normalAr: Vec3(n.x, 0, n.y), widthM: 3);
      // Model loaded with its pivot (1.5, 2.5) at AR (0, -0.5): its north
      // wall's inner face (tile z = 0.1) sits at AR z = −2.9.
      const pose = ManualPose(pos: Vec2(0, -0.5));
      final snap = ManualSnaps.snapToWall(pose, fp, [w])!;
      expect(snap.turnedRad, _near(degToRad(6), 1e-9));
      // The matched face now lies in the wall's plane.
      final m = snap.pose.arFromTile(fp.pivotTile);
      final mid = m.transformPoint(fp.tile(snap.face.mid)).xz;
      expect((mid - w.centerAr.xz).dot(n), _near(0, 1e-9));
      // …facing the same way as the wall.
      final nf = rotateXz(snap.face.normal, snap.pose.yawRad);
      expect(nf.dot(n), _near(1, 1e-9));
      expect(snap.movedM, greaterThan(0.2));
    });

    test('no wall within 25° / 1.5 m → null', () {
      final fp = _room();
      final w = ArPlane(id: 'far', kind: 'wall', centerAr: const Vec3(0, 1.2, -9), normalAr: const Vec3(0, 0, 1), widthM: 3);
      expect(ManualSnaps.snapToWall(const ManualPose(pos: Vec2(0, -0.5)), fp, [w]), isNull);
      final skew = rotateXz(const Vec2(0, 1), degToRad(40));
      final w2 = ArPlane(id: 'skew', kind: 'wall', centerAr: const Vec3(0, 1.2, -3), normalAr: Vec3(skew.x, 0, skew.y), widthM: 3);
      expect(ManualSnaps.snapToWall(const ManualPose(pos: Vec2(0, -0.5)), fp, [w2]), isNull);
      expect(ManualSnaps.snapToWall(const ManualPose(pos: Vec2(0, -0.5)), fp, const []), isNull);
    });
  });

  group('snap corner', () {
    test('room corners come from walls meeting near their extents', () {
      final north = _wall('n', const Vec2(-2, -3), const Vec2(1, -3), const Vec2(0, 1));
      final west = _wall('w', const Vec2(-2, -3), const Vec2(-2, 1), const Vec2(1, 0));
      final parallel = _wall('s', const Vec2(-2, 2), const Vec2(1, 2), const Vec2(0, -1));
      final corners = ManualSnaps.roomCorners([north, west, parallel]);
      // north × west at (−2, −3); west × south at (−2, 2) is 1 m past the
      // west wall's end, beyond the 0.6 m slack.
      expect(corners, hasLength(1));
      _expectVec2(corners.single, const Vec2(-2, -3), 1e-9);
    });

    test('magnet radius: within 30 cm lands, beyond it does not', () {
      const room = [Vec2(0, 0), Vec2(4, 0)];
      _expectVec2(ManualSnaps.magnet(const Vec2(0.2, 0.2), room)!, const Vec2(0, 0));
      expect(ManualSnaps.magnet(const Vec2(0.25, 0.25), room), isNull, reason: '35 cm away');
      _expectVec2(ManualSnaps.magnet(const Vec2(3.9, 0), room)!, const Vec2(4, 0));
    });
  });

  group('footprint', () {
    test('room polygon, centroid pivot, faces both sides of each wall', () {
      final fp = _room();
      expect(fp.pivotTile.x, _near(1.5));
      expect(fp.pivotTile.z, _near(2.5));
      expect(fp.outline, hasLength(4));
      expect(fp.faces, hasLength(8));
      // Corners: no manifest corners, so the outline's.
      expect(fp.corners, hasLength(4));
    });

    test('manifest inside corners inside the room win as handles', () {
      final fp = ModelFootprint.build(
        floorTileY: 0.02,
        room: const [Vec2(0, 0), Vec2(3, 0), Vec2(3, 5), Vec2(0, 5)],
        modelCorners: const [
          (Vec2(0.1, 0.1), Vec2(1, 0), Vec2(0, 1), 'inside'),
          (Vec2(2.9, 0.1), Vec2(-1, 0), Vec2(0, 1), 'inside'),
          (Vec2(2.9, 4.9), Vec2(-1, 0), Vec2(0, -1), 'inside'),
          (Vec2(9, 9), Vec2(-1, 0), Vec2(0, -1), 'inside'),
          (Vec2(1, 1), Vec2(-1, 0), Vec2(0, -1), 'column'),
        ],
      );
      expect(fp.corners, hasLength(3));
      expect(fp.floorTileY, 0.02);
    });

    test('nothing at all → a 4 m square at the origin, never a crash', () {
      final fp = ModelFootprint.build(floorTileY: 0);
      expect(fp.outline, hasLength(4));
      expect(fp.pivotTile.x, _near(0));
      expect(fp.faces, hasLength(4));
    });
  });

  group('undo / redo', () {
    test('record, undo, redo, and a new change clears redo', () {
      final u = UndoStack<int>();
      expect(u.canUndo, isFalse);
      u.record(1); // 1 → 2
      u.record(2); // 2 → 3
      expect(u.undo(3), 2);
      expect(u.undo(2), 1);
      expect(u.undo(1), isNull);
      expect(u.redo(1), 2);
      expect(u.canRedo, isTrue);
      u.record(2); // a new change
      expect(u.canRedo, isFalse);
    });

    test('capacity keeps the newest', () {
      final u = UndoStack<int>(capacity: 3);
      for (var i = 0; i < 10; i++) {
        u.record(i);
      }
      expect(u.undoDepth, 3);
      expect(u.undo(10), 9);
    });
  });

  group('true size and the handed-over fit', () {
    test('the fit is manual, method manual, carries scale and says not true size', () {
      const pose = ManualPose(pos: Vec2(1, 2), floorY: -1.4, yawRad: 0.3, scale: 1.12);
      const placement = ManualPlacement(pose: pose, pivotTile: Vec3(1.5, 0, 2.5));
      final fit = placement.toFit();
      expect(fit.quality, AlignmentQuality.manual);
      expect(fit.method, 'manual');
      expect(fit.isHandPlaced, isTrue);
      expect(fit.isPlaced, isTrue);
      expect(fit.isTrueSize, isFalse);
      expect(fit.scale, 1.12);
      // arToTile undoes the scale (the general inverse).
      final tile = fit.arToTile(fit.tileToAr(const Vec3(0.3, 0.2, -1)));
      expect(tile.x, _near(0.3, 1e-9));
      expect(tile.z, _near(-1, 1e-9));
      // withQuality keeps the size.
      expect(fit.withQuality(AlignmentQuality.drifting).scale, 1.12);
    });

    test('a true-size placement is true size; a measured fit always is', () {
      const placement = ManualPlacement(pose: ManualPose(pos: Vec2(0, 0)), pivotTile: Vec3.zero);
      expect(placement.toFit().isTrueSize, isTrue);
      expect(AlignmentFit.none().isTrueSize, isTrue);
      expect(AlignmentFit.none().isHandPlaced, isFalse);
    });

    test('shifted follows the anchor in all three axes', () {
      const placement = ManualPlacement(pose: ManualPose(pos: Vec2(1, 1), floorY: 0), pivotTile: Vec3.zero);
      final moved = placement.shifted(const Vec3(0.02, -0.01, 0.03));
      _expectVec2(moved.pose.pos, const Vec2(1.02, 1.03));
      expect(moved.pose.floorY, _near(-0.01));
    });
  });

  group('coach and advice', () {
    test('coach steps in order', () {
      expect(ManualCoach.step(placed: false, moved: false, turned: false, sized: false), ManualCoachStep.floor);
      expect(ManualCoach.step(placed: true, moved: false, turned: false, sized: false), ManualCoachStep.drag);
      expect(ManualCoach.step(placed: true, moved: true, turned: false, sized: false), ManualCoachStep.twist);
      expect(ManualCoach.step(placed: true, moved: true, turned: true, sized: false), ManualCoachStep.pinch);
      expect(ManualCoach.step(placed: true, moved: true, turned: true, sized: true), ManualCoachStep.lock);
      expect(ManualCoach.key(ManualCoachStep.twist), 'ar.manual.coach.twist');
    });

    test('suggested first with few corners or after two failed corner tries', () {
      expect(ManualAdvice.recommend(corners: 0, cornerFailures: 0, boardFirst: false), isTrue);
      expect(ManualAdvice.recommend(corners: 4, cornerFailures: 0, boardFirst: false), isFalse);
      expect(ManualAdvice.recommend(corners: 4, cornerFailures: 2, boardFirst: false), isTrue);
      expect(ManualAdvice.recommend(corners: 1, cornerFailures: 0, boardFirst: true), isFalse, reason: 'a board here is better');
      expect(ManualAdvice.recommend(corners: 1, cornerFailures: 2, boardFirst: true), isTrue);
    });
  });

  group('pinhole camera (Demo / fake engine)', () {
    test('ray and projection agree', () {
      final cam = PinholeCamera.lookingAt(const Vec3(0, 1.5, 0), const Vec3(0, 0, -2), width: 390, height: 844);
      final r = cam.ray(120, 600);
      final hit = ManualGestures.floorHit(r, 0)!;
      final back = cam.project(hit)!;
      expect(back.$1, _near(120, 1e-6));
      expect(back.$2, _near(600, 1e-6));
      expect(back.$3, isTrue);
      expect(cam.project(const Vec3(0, 1.5, 5)), isNull, reason: 'behind the camera');
      expect(r.dirAr.length, _near(1, _eps));
    });
  });

  group('wire types', () {
    test('ArPlanes / ArRay parse tolerantly', () {
      final planes = ArPlanes.fromMap({
        'floorY': '-1.42',
        'planes': [
          {
            'id': 'p1',
            'kind': 'wall',
            'centerAr': [0, 1, -3],
            'normalAr': [0, 0, 2],
            'segment': [
              [-1, -3],
              [1, -3],
            ],
            'widthM': 2,
          },
          {'id': 'bad'},
          {'id': 'f', 'kind': 'floor', 'centerAr': [0, -1.4, 0], 'normalAr': [0, 1, 0]},
        ],
      });
      expect(planes.floorY, _near(-1.42));
      expect(planes.planes, hasLength(2));
      expect(planes.walls.single.normalAr.z, _near(1));
      expect(planes.walls.single.segment!.$2.x, 1);
      expect(ArPlanes.fromMap(null).planes, isEmpty);
      expect(ArRay.fromMap({'originAr': [0, 1, 0], 'dirAr': [0, -2, 0]})!.dirAr.y, _near(-1));
      expect(ArRay.fromMap({'originAr': [0, 1, 0], 'dirAr': [0, 0, 0]}), isNull);
    });
  });
}
