import 'package:technician_portal/core/ar/corner_matcher.dart' show CornerCandidate;
import 'package:technician_portal/core/ar/vec.dart';
import 'package:technician_portal/domain/ar_models.dart' show ManifestTile;
import 'package:technician_portal/state/ar_engine_bridge.dart' show ArTile;
import 'package:technician_portal/state/ar_gateway.dart';
import 'package:technician_portal/state/ar_view_models.dart';
import 'package:technician_portal/state/bim_viewer_pack.dart';

/// Shared fakes for the model viewer tests (not a test file itself): a
/// fake AR gateway with one floor, its plan and a pump, and a fake
/// solid-wall pack. House rule: hand-written `implements` fakes.

ArTile viewerTile(String hash, String layer, {double y = 0, int bytes = 100, String buildId = 'b1'}) => ManifestTile(
      hash: hash,
      url: '/api/bim/ar/tiles/$hash',
      bytes: bytes,
      layer: layer,
      bboxMin: Vec3(0, y, 0),
      bboxMax: Vec3(8, y + 3, 8),
      triangleCount: 10,
      buildId: buildId,
    );

final tileMep = viewerTile('m' * 64, 'mep');
final tileEdges = viewerTile('e' * 64, 'architecture', y: -1.55);
final tileSolid = viewerTile('s' * 64, 'architecture_solid', y: -1.55);

const featurePump = ArFeature(
  buildId: 'b1',
  featureId: 42,
  globalId: 'PUMP-GID',
  assetId: 'asset-pump',
  name: 'CHW pump P-01',
  discipline: 'plumbing',
  ifcType: 'IFCPUMP',
  bboxMin: Vec3(4, 0, 4),
  bboxMax: Vec3(5, 1, 5),
);

const planPlantRoom = ArPlan(
  minX: -1,
  minZ: -1,
  maxX: 21,
  maxZ: 11,
  walls: [
    [Vec2(0, 0), Vec2(20, 0), Vec2(20, 10), Vec2(0, 10), Vec2(0, 0)],
  ],
  spaces: [
    ArPlanSpace(name: 'Plant room', polygon: [Vec2(0, 0), Vec2(20, 0), Vec2(20, 10), Vec2(0, 10)], labelAt: Vec2(10, 5)),
  ],
  equipment: [
    ArPlanEquipment(name: 'Pump', polygon: [Vec2(4, 4), Vec2(5, 4), Vec2(5, 5), Vec2(4, 5)], globalId: 'PUMP-GID', assetId: 'asset-pump'),
  ],
);

class FakeViewerGateway implements ArGateway {
  FakeViewerGateway({this.demo = false, this.corners = const []});

  final bool demo;
  final List<CornerCandidate> corners;
  final onDevice = <String, String>{};
  var floorError = false;

  /// What the failure says when [floorError] is set (arErrorKey reads it).
  var floorErrorText = 'network: offline';

  /// A floor with no model at all: no tiles, no plan (no build published).
  var empty = false;
  var downloads = 0;

  @override
  bool get isDemo => demo;

  @override
  Future<ArFloorContext> floorContext(String floorId, {String? focusCode}) async {
    if (floorError) throw Exception(floorErrorText);
    return ArFloorContext(
      buildingId: 'bld',
      buildingName: 'Tower A',
      floorId: floorId,
      floorName: 'Level 3',
      builds: const [ArBuildRef(buildId: 'b1', lineage: 'mep', modelName: 'MEP')],
      tiles: empty ? const [] : [tileMep, tileEdges],
      markers: const [],
      corners: corners,
      gridLines: empty ? const [] : const [ArGridLine(name: 'A', p0: Vec2(0, 0), p1: Vec2(0, 10))],
      floorFinishOffsetM: 0.05,
    );
  }

  @override
  Future<ArPlan?> floorPlan(String floorId) async => empty ? null : planPlantRoom;

  @override
  Future<List<ArFeature>> features(ArFloorContext floor, {Set<String>? tileHashes}) async => const [featurePump];

  @override
  Future<Map<String, String>> tilePaths(List<ArTile> tiles) async => {
        for (final t in tiles)
          if (onDevice.containsKey(t.hash)) t.hash: onDevice[t.hash]!,
      };

  @override
  Future<void> download(ArFloorContext floor, {void Function(ArDownloadProgress progress)? onProgress}) async {
    downloads++;
    onProgress?.call(const ArDownloadProgress(doneBytes: 100, totalBytes: 200));
    for (final t in floor.tiles) {
      onDevice[t.hash] = '/tiles/${t.hash}.glb';
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class FakeViewerPack implements BimViewerPack {
  FakeViewerPack(this.gateway, {this.tiles = const []});
  final FakeViewerGateway gateway;
  final List<ArTile> tiles;
  var downloads = 0;

  @override
  Future<List<ArTile>> solidTiles(String floorId) async => tiles;

  @override
  Future<void> download(String floorId, {void Function(ArDownloadProgress progress)? onProgress}) async {
    downloads++;
    for (final t in tiles) {
      gateway.onDevice[t.hash] = '/tiles/${t.hash}.glb';
    }
  }
}
