import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/core/ar/drill_check.dart';
import 'package:technician_portal/core/ar/vec.dart';

const _check = DrillCheck();

/// A 10 m wall along +x at z = 0, 20 cm thick: faces at z = ±0.1.
const _wall = DrillWall(polyline: [Vec2(0, 0), Vec2(10, 0)], thicknessM: 0.2);

/// Standing 2 m in front of it (on the +z side), eyes 1.5 m up, facing it.
const _eye = Vec3(5, 1.5, 2);
const _toWall = Vec3(0, 0, -1);

DrillService<String> _svc(String id, Vec3 min, Vec3 max) => DrillService(ref: id, bboxMin: min, bboxMax: max);

void main() {
  group('drill point: the camera-centre ray on a wall face', () {
    test('hits the near face, at eye height, facing the camera', () {
      final hit = _check.cast(origin: _eye, direction: _toWall, walls: const [_wall], floorY: 0)!;
      expect(hit.point.distanceTo(const Vec3(5, 1.5, 0.1)), lessThan(1e-9));
      expect(hit.distanceM, closeTo(1.9, 1e-9));
      expect(hit.heightAboveFloorM, closeTo(1.5, 1e-9));
      expect(hit.faceNormal, const Vec2(0, 1), reason: 'out of the wall, towards the camera');
    });

    test('the face on the camera side, from either side of the wall', () {
      final hit = _check.cast(origin: const Vec3(5, 1.5, -2), direction: const Vec3(0, 0, 1), walls: const [_wall], floorY: 0)!;
      expect(hit.point.z, closeTo(-0.1, 1e-9));
      expect(hit.faceNormal, const Vec2(0, -1));
    });

    test('the nearest of two walls wins', () {
      const far = DrillWall(polyline: [Vec2(0, -3), Vec2(10, -3)]);
      final hit = _check.cast(origin: _eye, direction: _toWall, walls: const [far, _wall], floorY: 0)!;
      expect(hit.wallIndex, 1);
      expect(hit.point.z, closeTo(0.1, 1e-9));
    });

    test('heights are measured from the finished floor, not tile zero', () {
      final hit = _check.cast(origin: const Vec3(5, 4.5, 2), direction: _toWall, walls: const [_wall], floorY: 3)!;
      expect(hit.heightAboveFloorM, closeTo(1.5, 1e-9));
    });

    test('misses: facing away, along the wall, past its end, over its top', () {
      expect(_check.cast(origin: _eye, direction: const Vec3(0, 0, 1), walls: const [_wall], floorY: 0), isNull);
      expect(_check.cast(origin: _eye, direction: const Vec3(1, 0, 0), walls: const [_wall], floorY: 0), isNull);
      expect(_check.cast(origin: const Vec3(12, 1.5, 2), direction: _toWall, walls: const [_wall], floorY: 0), isNull);
      expect(
        _check.cast(origin: _eye, direction: const Vec3(0, 1, -1), walls: const [_wall], floorY: 0),
        isNull,
        reason: 'the ray reaches the face 3.4 m up, above the 3.2 m wall',
      );
      expect(_check.cast(origin: _eye, direction: _toWall, walls: const [], floorY: 0), isNull);
    });

    test('a camera inside a wall\'s thickness never hits that wall', () {
      expect(_check.cast(origin: const Vec3(5, 1.5, 0.05), direction: _toWall, walls: const [_wall], floorY: 0), isNull);
    });
  });

  group('services behind the drill point', () {
    final services = [
      // Cold water 20 mm in the wall, just below the point, 4 cm behind the face.
      _svc('cold-water', const Vec3(0, 1.40, 0.04), const Vec3(10, 1.42, 0.06)),
      // A vertical conduit 25 cm to the right, 8 cm deep.
      _svc('conduit-right', const Vec3(5.25, 0.3, 0.0), const Vec3(5.27, 2.5, 0.02)),
      // 38 cm to the left.
      _svc('conduit-left', const Vec3(4.60, 0.3, 0.0), const Vec3(4.62, 2.5, 0.02)),
      // In the room next door: too deep for a drill.
      _svc('next-room', const Vec3(4.9, 1.4, -0.5), const Vec3(5.1, 1.6, -0.3)),
      // In this room, in front of the face: seen, not drilled.
      _svc('in-room', const Vec3(4.9, 1.4, 0.3), const Vec3(5.1, 1.6, 0.5)),
      // Behind the face but 2 m away along the wall.
      _svc('far-along', const Vec3(7.0, 1.4, 0.0), const Vec3(7.2, 1.6, 0.02)),
    ];

    test('ranks by distance in the wall plane; too deep, in front or far away are left out', () {
      final r = _check.run(origin: _eye, direction: _toWall, walls: const [_wall], floorY: 0, services: services);
      expect(r.findings.map((f) => f.ref), ['cold-water', 'conduit-right', 'conduit-left']);
      expect(r.nearest!.ref, 'cold-water');
    });

    test('distance, direction and depth as the user facing the wall sees them', () {
      final r = _check.run(origin: _eye, direction: _toWall, walls: const [_wall], floorY: 0, services: services);
      final byId = {for (final f in r.findings) f.ref: f};
      expect(byId['cold-water']!.planeDistanceM, closeTo(0.08, 1e-9));
      expect(byId['cold-water']!.direction, DrillDirection.below);
      expect(byId['cold-water']!.depthM, closeTo(0.04, 1e-9));
      expect(byId['conduit-right']!.planeDistanceM, closeTo(0.25, 1e-9));
      expect(byId['conduit-right']!.direction, DrillDirection.right);
      expect(byId['conduit-right']!.depthM, closeTo(0.08, 1e-9));
      expect(byId['conduit-left']!.direction, DrillDirection.left);
    });

    test('directly behind the point, and above it', () {
      final r = _check.run(
        origin: _eye,
        direction: _toWall,
        walls: const [_wall],
        floorY: 0,
        services: [
          _svc('behind', const Vec3(4.9, 1.45, -0.02), const Vec3(5.1, 1.55, 0.0)),
          _svc('above', const Vec3(4.9, 1.7, -0.02), const Vec3(5.1, 1.8, 0.0)),
        ],
      );
      expect(r.findings.first.ref, 'behind');
      expect(r.findings.first.direction, DrillDirection.behind);
      expect(r.findings.first.planeDistanceM, 0);
      expect(r.findings.first.depthM, closeTo(0.10, 1e-9));
      expect(r.findings[1].direction, DrillDirection.above);
      expect(r.findings[1].planeDistanceM, closeTo(0.2, 1e-9));
    });

    test('left and right follow the view on a wall that runs along z', () {
      const wallZ = DrillWall(polyline: [Vec2(0, 0), Vec2(0, 10)]);
      // Facing −x: the view's right is −z.
      final r = _check.run(
        origin: const Vec3(2, 1.5, 5),
        direction: const Vec3(-1, 0, 0),
        walls: const [wallZ],
        floorY: 0,
        services: [
          _svc('smaller-z', const Vec3(0.0, 1.0, 4.6), const Vec3(0.02, 2.0, 4.62)),
          _svc('larger-z', const Vec3(0.0, 1.0, 5.5), const Vec3(0.02, 2.0, 5.52)),
        ],
      );
      final byId = {for (final f in r.findings) f.ref: f};
      expect(byId['smaller-z']!.direction, DrillDirection.right);
      expect(byId['larger-z']!.direction, DrillDirection.left);
    });

    test('verdict: red under 15 cm, amber to 30 cm, green beyond or with nothing near', () {
      expect(_check.verdictFor(0.08), DrillVerdict.danger);
      expect(_check.verdictFor(0.15), DrillVerdict.caution);
      expect(_check.verdictFor(0.29), DrillVerdict.caution);
      expect(_check.verdictFor(0.30), DrillVerdict.safe);
      expect(_check.verdictFor(null), DrillVerdict.safe);
      final clear = _check.run(
        origin: _eye,
        direction: _toWall,
        walls: const [_wall],
        floorY: 0,
        services: [_svc('conduit-left', const Vec3(4.58, 0.3, 0.0), const Vec3(4.60, 2.5, 0.02))],
      );
      expect(clear.verdict, DrillVerdict.safe);
      expect(clear.nearest!.planeDistanceM, closeTo(0.40, 1e-9), reason: 'still reported as the nearest');
      final miss = _check.run(origin: _eye, direction: const Vec3(0, 0, 1), walls: const [_wall], floorY: 0, services: services);
      expect(miss.hit, isNull);
      expect(miss.verdict, isNull);
    });
  });

  group('where an element is concealed', () {
    test('in a wall: footprint within the thickness, cover to the nearer face', () {
      final p = _check.place(bboxMin: const Vec3(0, 1.40, 0.04), bboxMax: const Vec3(10, 1.42, 0.06), floorY: 0, walls: const [_wall]);
      expect(p.zone, ServiceZone.inWall);
      expect(p.behindFaceM, closeTo(0.04, 1e-9));
      expect(p.bottomM, closeTo(1.40, 1e-9));
      expect(p.concealed, isTrue);
    });

    test('a pipe crossing the wall is not "in" it', () {
      final p = _check.place(bboxMin: const Vec3(5, 1.4, -1), bboxMax: const Vec3(5.02, 1.42, 1), floorY: 0, walls: const [_wall]);
      expect(p.zone, ServiceZone.room);
      expect(p.concealed, isFalse);
    });

    test('above the ceiling, or in the slab when a slab box holds it', () {
      const min = Vec3(3, 3.0, 3);
      const max = Vec3(6, 3.1, 3.1);
      expect(_check.place(bboxMin: min, bboxMax: max, floorY: 0).zone, ServiceZone.aboveCeiling);
      final inSlab = _check.place(bboxMin: min, bboxMax: max, floorY: 0, slabs: const [(Vec3(0, 2.95, 0), Vec3(10, 3.2, 10))]);
      expect(inSlab.zone, ServiceZone.inSlab);
    });

    test('in the floor, relative to the finished floor datum', () {
      final p = _check.place(bboxMin: const Vec3(1, 2.90, 1), bboxMax: const Vec3(4, 2.95, 1.05), floorY: 3.0);
      expect(p.zone, ServiceZone.inFloor);
      expect(p.topM, closeTo(-0.05, 1e-9));
    });
  });
}
