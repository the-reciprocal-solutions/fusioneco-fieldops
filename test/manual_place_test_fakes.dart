import 'package:technician_portal/core/ar/ar_engine.dart';
import 'package:technician_portal/core/ar/manual_place_math.dart';
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/core/offline/offline_db.dart' show ArPackStore;
import 'package:technician_portal/state/ar_manual_place_controller.dart';
import 'package:technician_portal/state/ar_session_controller.dart';
import 'package:technician_portal/state/ar_setup_controller.dart';
import 'package:technician_portal/state/ar_view_models.dart';

import 'ar_workspace_fakes.dart';

/// Shared by the "Place by hand" tests: the demo bedroom's shape (10 × 16 ft
/// ≈ 3.05 × 4.88 m), a camera standing in it, and fakes of the seams.

const bedroom = [Vec2(0, 0), Vec2(3.05, 0), Vec2(3.05, 4.88), Vec2(0, 4.88)];

const bedroomFloor = ArFloorContext(
  buildingId: 'b1',
  buildingName: 'Demo house',
  floorId: 'f-bed',
  floorName: 'Ground',
  builds: [],
  tiles: [],
  markers: [],
  corners: [],
  gridLines: [],
);

const bedroomPlan = ArPlan(
  minX: -0.2,
  minZ: -0.2,
  maxX: 3.25,
  maxZ: 5.08,
  walls: [
    [Vec2(-0.1, -0.1), Vec2(3.15, -0.1), Vec2(3.15, 4.98), Vec2(-0.1, 4.98), Vec2(-0.1, -0.1)],
  ],
  wallThicknesses: [0.2],
  spaces: [ArPlanSpace(name: 'Bedroom', polygon: bedroom, labelAt: Vec2(1.5, 2.4))],
);

ArSessionState manualSession({bool demo = false}) => ArSessionState(
  phase: ArSessionPhase.running,
  stage: ArSessionStage.setup,
  demo: demo,
  floor: bedroomFloor,
  plan: bedroomPlan,
  cameraAr: const Vec3(0, 1.5, 0),
  cameraForwardAr: const Vec3(0, 0, -1),
);

/// Rays and projections through one pinhole camera at (0, 1.5, 0) looking
/// down −Z at the floor; walls and a native corner as the test sets them.
class TestManualIo implements ManualViewIo {
  TestManualIo({this.walls = const [], this.floorY = 0, double width = 390, double height = 844})
      : camera = PinholeCamera.lookingAt(const Vec3(0, 1.5, 0), const Vec3(0, 0, -2), width: width, height: height);

  final PinholeCamera camera;
  List<ArPlane> walls;
  double? floorY;
  Vec2? nativeCorner;
  var rayCalls = 0;

  @override
  Future<List<ArRay?>> rays(List<(double, double)> points) async {
    rayCalls++;
    return [for (final (x, y) in points) camera.ray(x, y)];
  }

  @override
  Future<List<(double, double, bool)?>> project(List<Vec3> worldAr, Mat4 arFromTile) async =>
      [for (final w in worldAr) camera.project(w)];

  @override
  Future<ArPlanes> planes() async => ArPlanes(floorY: floorY, planes: walls);

  @override
  Future<Vec2?> cornerAt(double x, double y) async => nativeCorner;
}

/// A wall plane through two floor points, normal facing into the room.
ArPlane testWall(String id, Vec2 a, Vec2 b, Vec2 normal) => ArPlane(
      id: id,
      kind: 'wall',
      centerAr: Vec3((a.x + b.x) / 2, 1.2, (a.y + b.y) / 2),
      normalAr: Vec3(normal.x, 0, normal.y).normalized,
      segment: (a, b),
      widthM: a.distanceTo(b),
      heightM: 2.4,
    );

/// [FakeSession] that records the live preview frames. Everything else
/// (applyManualPlacement, the fit, the badge) is the real session code.
class ManualFakeSession extends FakeSession {
  ManualFakeSession(ArSessionState initial) : super(initial, FakeGateway());

  final previews = <Mat4>[];
  final opacities = <double>[];
  final toasts = <String>[];

  @override
  Future<void> previewModelTransform(Mat4 arFromTile) async {
    if (manualPreviewing) previews.add(arFromTile);
  }

  @override
  Future<void> setLayers({
    required bool mep,
    required bool structure,
    required bool architecture,
    required double opacity,
    double? sectionY,
  }) async {
    opacities.add(opacity);
  }

  @override
  void toast(String key, {List<Object> args = const [], ArToastTone tone = ArToastTone.info}) => toasts.add(key);
}

class IdleSetup extends ArSetupController {
  @override
  ArSetupState build() => const ArSetupState();
}

/// Only the two pref calls.
class PrefStore implements ArPackStore {
  final prefs = <String, String>{};

  @override
  Future<String?> getArPref(String key) async => prefs[key];

  @override
  Future<void> setArPref(String key, String? value) async {
    if (value == null) {
      prefs.remove(key);
    } else {
      prefs[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}
