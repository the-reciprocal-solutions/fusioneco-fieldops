import 'dart:math' as math;

import '../core/ar/alignment_estimator.dart';
import '../core/ar/corner_matcher.dart' show CornerCandidate;
import '../core/ar/marker_code.dart';
import '../core/ar/vec.dart';
import '../core/network/envelope.dart';

// Dart models for the AR API (`/api/bim/ar`, CONTRACT C6). Every parser is
// tolerant in the house way ([envelope.dart]): any of the four envelope
// shapes, numbers that arrive as strings (Sequelize DECIMAL), vectors as
// `[x, y, z]` or `{x, y, z}`, and a bad row skipped rather than crashing a
// whole floor. Coordinates are in the **tile frame** (Y-up metres) unless a
// field name says `Project` (IFC world, Z-up).

// ---------------------------------------------------------------- helpers

String? _str(dynamic v) {
  final s = v?.toString().trim();
  return s == null || s.isEmpty ? null : s;
}

List<Map<String, dynamic>> _maps(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : <Map<String, dynamic>>[];

List<String> _strings(dynamic v) => v is List
    ? v.map(_str).whereType<String>().toList()
    : <String>[];

List<Vec2> _points(dynamic v) => v is List
    ? v.map(Vec2.tryParse).whereType<Vec2>().toList()
    : <Vec2>[];

/// The manifest, floors and features endpoints may answer with the payload
/// at the top level or under `data`; a list endpoint may also wrap its rows
/// as `{data: {rows: [...]}}` or `{items: [...]}`.
List<Map<String, dynamic>> _rows(dynamic body) {
  final data = unwrap(body);
  if (data is List) return _maps(data);
  if (data is Map) {
    for (final key in const ['rows', 'items', 'floors', 'features', 'markers']) {
      if (data[key] is List) return _maps(data[key]);
    }
  }
  return <Map<String, dynamic>>[];
}

// ------------------------------------------------------------------ floors

/// A model lineage's state on one floor (`GET /buildings/:id/floors`).
class ArFloorModel {
  const ArFloorModel({
    required this.lineage,
    required this.modelName,
    required this.status,
    this.buildId,
    this.version,
    this.publishedAt,
    this.bytes = 0,
    this.reason,
    this.onDevice = false,
    this.updateAvailable = false,
  });

  static ArFloorModel? fromJson(Map<String, dynamic> json) {
    final lineage = _str(json['lineage']);
    if (lineage == null) return null;
    return ArFloorModel(
      lineage: lineage,
      modelName: _str(json['modelName']) ?? lineage,
      buildId: _str(json['buildId']),
      version: asInt(json['version']),
      publishedAt: asDate(json['publishedAt']),
      bytes: asInt(json['bytes']) ?? 0,
      status: _str(json['status']) ?? ArModelStatus.noIfc,
      reason: _str(json['reason']),
    );
  }

  final String lineage;
  final String modelName;
  final String? buildId;
  final int? version;
  final DateTime? publishedAt;

  /// Download size of this model's tiles on the floor.
  final int bytes;

  /// [ArModelStatus] values: `ready | building | failed | no-ifc`.
  final String status;

  /// Why the model can't be used ("source IFC missing"), shown as is.
  final String? reason;

  /// Local: this build's tiles are on the phone.
  final bool onDevice;

  /// Local: an older build of this lineage is on the phone.
  final bool updateAvailable;

  bool get isReady => status == ArModelStatus.ready && buildId != null;

  ArFloorModel withLocal({required bool onDevice, required bool updateAvailable}) =>
      ArFloorModel(
        lineage: lineage,
        modelName: modelName,
        status: status,
        buildId: buildId,
        version: version,
        publishedAt: publishedAt,
        bytes: bytes,
        reason: reason,
        onDevice: onDevice,
        updateAvailable: updateAvailable,
      );
}

abstract final class ArModelStatus {
  static const ready = 'ready';
  static const building = 'building';
  static const failed = 'failed';
  static const noIfc = 'no-ifc';
}

/// One floor of a building as the AR models picker lists it.
class ArFloorSummary {
  const ArFloorSummary({
    required this.floorId,
    required this.name,
    this.elevation,
    this.models = const [],
    this.markerCount = 0,
    this.cornerCount = 0,
    this.gridNames = const [],
    this.downloadedAt,
  });

  static ArFloorSummary? fromJson(Map<String, dynamic> json) {
    final id = _str(json['floorId'] ?? json['id']);
    if (id == null) return null;
    return ArFloorSummary(
      floorId: id,
      name: _str(json['name'] ?? json['floorName']) ?? id,
      elevation: asDouble(json['elevation']),
      models: _maps(json['models']).map(ArFloorModel.fromJson).whereType<ArFloorModel>().toList(),
      markerCount: asInt(json['markerCount']) ?? 0,
      cornerCount: asInt(json['cornerCount']) ?? 0,
      gridNames: _strings(json['gridNames']),
    );
  }

  static List<ArFloorSummary> listFromBody(dynamic body) =>
      _rows(body).map(fromJson).whereType<ArFloorSummary>().toList();

  final String floorId;
  final String name;
  final double? elevation;
  final List<ArFloorModel> models;
  final int markerCount;
  final int cornerCount;
  final List<String> gridNames;

  /// Local: when this floor's pack was last saved on the phone, or null.
  final DateTime? downloadedAt;

  List<ArFloorModel> get readyModels => models.where((m) => m.isReady).toList();

  bool get hasBoards => markerCount > 0;
  bool get isOnDevice => downloadedAt != null;

  /// The method the chooser should recommend here (AR-54): a board when this
  /// floor has any, otherwise corners. Gridlines when there are no corners
  /// but there is a grid.
  String get recommendedMethod {
    if (hasBoards) return ArSetupMethod.board;
    if (cornerCount == 0 && gridNames.isNotEmpty) return ArSetupMethod.grid;
    return ArSetupMethod.corners;
  }

  int get readyBytes => readyModels.fold(0, (sum, m) => sum + m.bytes);

  ArFloorSummary copyWith({List<ArFloorModel>? models, DateTime? downloadedAt}) =>
      ArFloorSummary(
        floorId: floorId,
        name: name,
        elevation: elevation,
        models: models ?? this.models,
        markerCount: markerCount,
        cornerCount: cornerCount,
        gridNames: gridNames,
        downloadedAt: downloadedAt ?? this.downloadedAt,
      );
}

/// Setup methods (docs/ar-setup-and-gamma-parity.md §2.9, `/ar/session?method=`).
abstract final class ArSetupMethod {
  static const board = 'board';
  static const corners = 'corners';
  static const grid = 'grid';
  static const resume = 'resume';
}

// ---------------------------------------------------------------- manifest

class ArBuildRef {
  const ArBuildRef({
    required this.buildId,
    required this.lineage,
    required this.modelName,
    this.version,
    this.publishedAt,
    this.coordMatrix,
    this.buildingFrame,
  });

  static ArBuildRef? fromJson(Map<String, dynamic> json) {
    final id = _str(json['buildId'] ?? json['id']);
    if (id == null) return null;
    return ArBuildRef(
      buildId: id,
      lineage: _str(json['lineage']) ?? '',
      modelName: _str(json['modelName']) ?? _str(json['lineage']) ?? '',
      version: asInt(json['version'] ?? json['versionNo']),
      publishedAt: asDate(json['publishedAt']),
      coordMatrix: Mat4.tryParse(json['coordMatrix']),
      buildingFrame: Mat4.tryParse(json['buildingFrame']),
    );
  }

  final String buildId;
  final String lineage;
  final String modelName;
  final int? version;
  final DateTime? publishedAt;
  final Mat4? coordMatrix;

  /// The building's one frame (CONTRACT C2). Null only for a malformed row.
  final Mat4? buildingFrame;
}

abstract final class ArLayer {
  static const mep = 'mep';
  static const structure = 'structure';
  static const architecture = 'architecture';
}

/// One content-addressed tile (CONTRACT C7).
class ManifestTile {
  const ManifestTile({
    required this.hash,
    required this.url,
    required this.bytes,
    required this.layer,
    required this.bboxMin,
    required this.bboxMax,
    required this.triangleCount,
    required this.buildId,
  });

  static ManifestTile? fromJson(Map<String, dynamic> json) {
    final hash = _str(json['hash']);
    final min = Vec3.tryParse(json['bboxMin']);
    final max = Vec3.tryParse(json['bboxMax']);
    if (hash == null || min == null || max == null) return null;
    return ManifestTile(
      hash: hash,
      url: _str(json['url']) ?? '/api/bim/ar/tiles/$hash',
      bytes: asInt(json['bytes']) ?? 0,
      layer: _str(json['layer']) ?? ArLayer.mep,
      bboxMin: min,
      bboxMax: max,
      triangleCount: asInt(json['triangleCount']) ?? 0,
      buildId: _str(json['buildId']) ?? '',
    );
  }

  final String hash;
  final String url;
  final int bytes;

  /// [ArLayer] values.
  final String layer;
  final Vec3 bboxMin;
  final Vec3 bboxMax;
  final int triangleCount;
  final String buildId;

  Vec3 get centre => (bboxMin + bboxMax) * 0.5;

  /// Distance from [p] to this tile's bounding box (0 inside it).
  double distanceTo(Vec3 p) {
    double axis(double v, double lo, double hi) => v < lo ? lo - v : (v > hi ? v - hi : 0);
    final dx = axis(p.x, bboxMin.x, bboxMax.x);
    final dy = axis(p.y, bboxMin.y, bboxMax.y);
    final dz = axis(p.z, bboxMin.z, bboxMax.z);
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  Map<String, dynamic> toJson() => {
        'hash': hash,
        'url': url,
        'bytes': bytes,
        'layer': layer,
        'bboxMin': bboxMin.toList(),
        'bboxMax': bboxMax.toList(),
        'triangleCount': triangleCount,
        'buildId': buildId,
      };
}

class ManifestFeatureRef {
  const ManifestFeatureRef({required this.buildId, required this.url});

  static ManifestFeatureRef? fromJson(Map<String, dynamic> json) {
    final id = _str(json['buildId']);
    if (id == null) return null;
    return ManifestFeatureRef(buildId: id, url: _str(json['url']) ?? '/api/bim/ar/features/$id');
  }

  final String buildId;
  final String url;
}

/// A structural grid line on the floor, `(x, z)` in the tile frame.
class ArGridLine {
  const ArGridLine({required this.name, required this.p0, required this.p1});

  static ArGridLine? fromJson(Map<String, dynamic> json) {
    final p0 = Vec2.tryParse(json['p0']);
    final p1 = Vec2.tryParse(json['p1']);
    if (p0 == null || p1 == null) return null;
    return ArGridLine(name: _str(json['name']) ?? '', p0: p0, p1: p1);
  }

  final String name;
  final Vec2 p0;
  final Vec2 p1;

  Map<String, dynamic> toJson() => {'name': name, 'p0': p0.toList(), 'p1': p1.toList()};
}

abstract final class ArMarkerStatus {
  static const spare = 'spare';
  static const planned = 'planned';
  static const printed = 'printed';
  static const installed = 'installed';
  static const active = 'active';
  static const suspect = 'suspect';
  static const needsReview = 'needs-review';
  static const retired = 'retired';
}

/// A board as the manifest carries it (CONTRACT C5 `ManifestMarker`).
class ManifestMarker {
  const ManifestMarker({
    required this.code,
    required this.label,
    required this.status,
    required this.accuracyClass,
    required this.mounting,
    required this.posTile,
    required this.normalTile,
    required this.sigmaM,
  });

  static ManifestMarker? fromJson(Map<String, dynamic> json) {
    final code = MarkerCode.normalize(_str(json['code']) ?? '');
    final pose = json['poseTile'];
    final pos = Vec3.tryParse(json['posTile'] ?? (pose is Map ? pose['p'] : null));
    final normal = Vec3.tryParse(json['normalTile'] ?? (pose is Map ? pose['n'] : null));
    if (code == null || pos == null || normal == null) return null;
    final accuracy = _str(json['accuracyClass']) ?? 'derived';
    return ManifestMarker(
      code: code,
      label: _str(json['label']) ?? MarkerCode.display(code),
      status: _str(json['status']) ?? ArMarkerStatus.active,
      accuracyClass: accuracy,
      mounting: _str(json['mounting']) ?? 'wall',
      posTile: pos,
      normalTile: normal,
      sigmaM: asDouble(json['sigmaM']) ?? ArSigma.forMarkerClass(accuracy),
    );
  }

  /// Canonical 7-char code.
  final String code;
  final String label;
  final String status;

  /// `surveyed | feature | derived`.
  final String accuracyClass;

  /// `wall | column | floor`.
  final String mounting;
  final Vec3 posTile;
  final Vec3 normalTile;
  final double sigmaM;

  String get codeDisplay => MarkerCode.display(code);

  Map<String, dynamic> toJson() => {
        'code': code,
        'label': label,
        'status': status,
        'accuracyClass': accuracyClass,
        'mounting': mounting,
        'posTile': posTile.toList(),
        'normalTile': normalTile.toList(),
        'sigmaM': sigmaM,
      };
}

/// `GET /manifest?scope=floor&id=&focus=` — everything the phone needs for
/// one floor, with the tiles near the focus board listed first.
class Manifest {
  const Manifest({
    required this.buildingId,
    required this.floorId,
    required this.floorName,
    this.floorFinishOffsetM = 0,
    this.builds = const [],
    this.tiles = const [],
    this.features = const [],
    this.corners = const [],
    this.gridLines = const [],
    this.markers = const [],
    this.etag,
    this.raw = const {},
    this.fromCache = false,
    this.notModified = false,
  });

  static Manifest? fromJson(Map<String, dynamic> json) {
    final floorId = _str(json['floorId']);
    if (floorId == null) return null;
    return Manifest(
      buildingId: _str(json['buildingId']) ?? '',
      floorId: floorId,
      floorName: _str(json['floorName']) ?? '',
      floorFinishOffsetM: asDouble(json['floorFinishOffsetM']) ?? 0,
      builds: _maps(json['builds']).map(ArBuildRef.fromJson).whereType<ArBuildRef>().toList(),
      tiles: _maps(json['tiles']).map(ManifestTile.fromJson).whereType<ManifestTile>().toList(),
      features: _maps(json['features'])
          .map(ManifestFeatureRef.fromJson)
          .whereType<ManifestFeatureRef>()
          .toList(),
      corners: _maps(json['corners']).map(CornerCandidate.fromJson).whereType<CornerCandidate>().toList(),
      gridLines: _maps(json['gridLines']).map(ArGridLine.fromJson).whereType<ArGridLine>().toList(),
      markers: _maps(json['markers']).map(ManifestMarker.fromJson).whereType<ManifestMarker>().toList(),
      etag: _str(json['etag']),
      raw: json,
    );
  }

  /// Any of the four envelope shapes.
  static Manifest? fromBody(dynamic body) {
    final map = unwrapMap(body);
    return map.isEmpty ? null : fromJson(map);
  }

  final String buildingId;
  final String floorId;
  final String floorName;

  /// Finished floor above the modelled slab (raised floor, screed).
  final double floorFinishOffsetM;
  final List<ArBuildRef> builds;

  /// Focus tiles first (within 15 m of the focus board), as the server sent them.
  final List<ManifestTile> tiles;
  final List<ManifestFeatureRef> features;
  final List<CornerCandidate> corners;
  final List<ArGridLine> gridLines;
  final List<ManifestMarker> markers;
  final String? etag;

  /// The JSON as the server sent it; what the local store persists, so a
  /// read-back parses exactly what was received.
  final Map<String, dynamic> raw;

  /// Local: served from the phone because the network was unreachable.
  final bool fromCache;

  /// Local: the server answered 304 and the stored copy is current.
  final bool notModified;

  /// The frame every build of this building shares. Null only when no
  /// build carries one (a malformed manifest: nothing can be aligned).
  Mat4? get buildingFrame {
    for (final b in builds) {
      if (b.buildingFrame != null) return b.buildingFrame;
    }
    return null;
  }

  int get totalBytes => tiles.fold(0, (sum, t) => sum + t.bytes);
  int get totalTriangles => tiles.fold(0, (sum, t) => sum + t.triangleCount);
  Set<String> get tileHashes => {for (final t in tiles) t.hash};

  ManifestMarker? markerByCode(String code) {
    final canonical = MarkerCode.normalize(code) ?? code;
    for (final m in markers) {
      if (m.code == canonical) return m;
    }
    return null;
  }

  /// Tiles whose box is within [radiusM] of [focus] — "3 MB around you
  /// first". With no focus, the first tiles the server listed.
  List<ManifestTile> focusTiles(Vec3? focus, {double radiusM = 15}) => focus == null
      ? const []
      : tiles.where((t) => t.distanceTo(focus) <= radiusM).toList();

  Manifest copyWith({bool? fromCache, bool? notModified, String? etag}) => Manifest(
        buildingId: buildingId,
        floorId: floorId,
        floorName: floorName,
        floorFinishOffsetM: floorFinishOffsetM,
        builds: builds,
        tiles: tiles,
        features: features,
        corners: corners,
        gridLines: gridLines,
        markers: markers,
        etag: etag ?? this.etag,
        raw: raw,
        fromCache: fromCache ?? this.fromCache,
        notModified: notModified ?? this.notModified,
      );
}

// ---------------------------------------------------------------- features

class ArFeatureTileRef {
  const ArFeatureTileRef({required this.hash, required this.localIndex});

  final String hash;
  final int localIndex;

  Map<String, dynamic> toJson() => {'hash': hash, 'localIndex': localIndex};
}

/// One BIM element on the device (`GET /features/:buildId`). The bridge
/// from a picked `featureId` to a GlobalId and on to the register asset.
class ArFeature {
  const ArFeature({
    required this.buildId,
    required this.featureId,
    required this.globalId,
    this.assetId,
    this.floorId,
    this.name,
    this.discipline = '',
    this.systemGlobalId,
    this.ifcType = '',
    this.bboxMin,
    this.bboxMax,
    this.tiles = const [],
    this.props = const {},
  });

  static ArFeature? fromJson(Map<String, dynamic> json, {String? buildId}) {
    final id = asInt(json['featureId']);
    final globalId = _str(json['globalId']);
    final build = _str(json['buildId']) ?? buildId;
    if (id == null || globalId == null || build == null) return null;
    final tiles = <ArFeatureTileRef>[];
    for (final t in _maps(json['tiles'])) {
      final hash = _str(t['hash']);
      final index = asInt(t['localIndex']);
      if (hash != null && index != null) tiles.add(ArFeatureTileRef(hash: hash, localIndex: index));
    }
    return ArFeature(
      buildId: build,
      featureId: id,
      globalId: globalId,
      assetId: _str(json['assetId']),
      floorId: _str(json['floorId']),
      name: _str(json['name']),
      discipline: _str(json['discipline']) ?? '',
      systemGlobalId: _str(json['systemGlobalId']),
      ifcType: _str(json['ifcType']) ?? '',
      bboxMin: Vec3.tryParse(json['bboxMin']),
      bboxMax: Vec3.tryParse(json['bboxMax']),
      tiles: tiles,
      props: {
        if (json['props'] is Map)
          for (final e in (json['props'] as Map).entries)
            if (e.value != null) e.key.toString(): e.value.toString(),
      },
    );
  }

  static List<ArFeature> listFromBody(dynamic body, {required String buildId}) =>
      _rows(body).map((j) => fromJson(j, buildId: buildId)).whereType<ArFeature>().toList();

  final String buildId;
  final int featureId;
  final String globalId;
  final String? assetId;
  final String? floorId;
  final String? name;
  final String discipline;
  final String? systemGlobalId;
  final String ifcType;
  final Vec3? bboxMin;
  final Vec3? bboxMax;
  final List<ArFeatureTileRef> tiles;

  /// IFC instance properties, `"<Pset>.<Property>": text` plus `Tag` and
  /// `ObjectType` (server builds from 2026-09-27; empty before).
  final Map<String, String> props;

  /// The first property named [name] in any property set (case-insensitive),
  /// e.g. `prop('SiteNote')`, `prop('Status')`, `prop('Manufacturer')`.
  String? prop(String name) {
    final n = name.toLowerCase();
    for (final e in props.entries) {
      final k = e.key.toLowerCase();
      if (k == n || k.endsWith('.$n')) {
        final v = e.value.trim();
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }

  Vec3? get centre =>
      bboxMin == null || bboxMax == null ? null : (bboxMin! + bboxMax!) * 0.5;

  Map<String, dynamic> toJson() => {
        'buildId': buildId,
        'featureId': featureId,
        'globalId': globalId,
        'assetId': assetId,
        'floorId': floorId,
        'name': name,
        'discipline': discipline,
        'systemGlobalId': systemGlobalId,
        'ifcType': ifcType,
        'bboxMin': bboxMin?.toList(),
        'bboxMax': bboxMax?.toList(),
        'tiles': [for (final t in tiles) t.toJson()],
        if (props.isNotEmpty) 'props': props,
      };
}

// -------------------------------------------------------------- floor plan

class PlanBounds {
  const PlanBounds(this.minX, this.minZ, this.maxX, this.maxZ);

  static PlanBounds? tryParse(dynamic raw) {
    if (raw is! List || raw.length < 4) return null;
    final v = raw.map(asDouble).toList();
    if (v.any((e) => e == null)) return null;
    return PlanBounds(v[0]!, v[1]!, v[2]!, v[3]!);
  }

  final double minX;
  final double minZ;
  final double maxX;
  final double maxZ;

  double get width => maxX - minX;
  double get depth => maxZ - minZ;
}

class PlanWall {
  const PlanWall({
    required this.polyline,
    this.id,
    this.globalId,
    this.thickness = 0.2,
    this.structural = false,
  });

  final String? id;
  final String? globalId;
  final List<Vec2> polyline;
  final double thickness;
  final bool structural;
}

class PlanColumn {
  const PlanColumn({required this.polygon, this.globalId});

  final String? globalId;
  final List<Vec2> polygon;
}

class PlanOpening {
  const PlanOpening({required this.kind, required this.a, required this.b});

  /// `door | window`.
  final String kind;
  final Vec2 a;
  final Vec2 b;
}

class PlanSpace {
  const PlanSpace({required this.name, required this.polygon, this.spaceId, this.labelAt});

  final String? spaceId;
  final String name;
  final List<Vec2> polygon;
  final Vec2? labelAt;
}

class PlanEquipment {
  const PlanEquipment({required this.polygon, this.globalId, this.name, this.assetId});

  final String? globalId;
  final String? name;
  final String? assetId;
  final List<Vec2> polygon;
}

/// `GET /floors/:floorId/plan` — the cut plan the mini plan, the corner
/// picker and the ghost-board chooser draw from, in tile XZ (x right, z down
/// on screen).
class FloorPlan {
  const FloorPlan({
    required this.floorId,
    this.bounds,
    this.walls = const [],
    this.columns = const [],
    this.openings = const [],
    this.spaces = const [],
    this.equipment = const [],
    this.gridLines = const [],
    this.corners = const [],
    this.fromCache = false,
  });

  /// A plan with only what a stored manifest carries (corners, grid lines),
  /// for a floor opened offline before its plan was ever fetched.
  factory FloorPlan.fromManifest(Manifest m) => FloorPlan(
        floorId: m.floorId,
        corners: m.corners,
        gridLines: m.gridLines,
        fromCache: true,
      );

  static FloorPlan? fromJson(Map<String, dynamic> json, {String? floorId}) {
    final id = _str(json['floorId']) ?? floorId;
    if (id == null) return null;
    return FloorPlan(
      floorId: id,
      bounds: PlanBounds.tryParse(json['bbox']),
      walls: [
        for (final w in _maps(json['walls']))
          if (_points(w['polyline']).length >= 2)
            PlanWall(
              id: _str(w['id']),
              globalId: _str(w['globalId']),
              polyline: _points(w['polyline']),
              thickness: asDouble(w['thickness']) ?? 0.2,
              structural: asBool(w['structural']) ?? false,
            ),
      ],
      columns: [
        for (final c in _maps(json['columns']))
          if (_points(c['polygon']).length >= 3)
            PlanColumn(globalId: _str(c['globalId']), polygon: _points(c['polygon'])),
      ],
      openings: [
        for (final o in _maps(json['openings']))
          if (_points(o['segment']).length >= 2)
            PlanOpening(
              kind: _str(o['kind']) ?? 'door',
              a: _points(o['segment'])[0],
              b: _points(o['segment'])[1],
            ),
      ],
      spaces: [
        for (final s in _maps(json['spaces']))
          if (_points(s['polygon']).length >= 3)
            PlanSpace(
              spaceId: _str(s['spaceId']),
              name: _str(s['name']) ?? '',
              polygon: _points(s['polygon']),
              labelAt: Vec2.tryParse(s['labelAt']),
            ),
      ],
      equipment: [
        for (final e in _maps(json['equipment']))
          if (_points(e['polygon']).length >= 3)
            PlanEquipment(
              globalId: _str(e['globalId']),
              name: _str(e['name']),
              assetId: _str(e['assetId']),
              polygon: _points(e['polygon']),
            ),
      ],
      gridLines: _maps(json['gridLines']).map(ArGridLine.fromJson).whereType<ArGridLine>().toList(),
      corners: _maps(json['corners']).map(CornerCandidate.fromJson).whereType<CornerCandidate>().toList(),
    );
  }

  static FloorPlan? fromBody(dynamic body, {String? floorId}) {
    final map = unwrapMap(body);
    return map.isEmpty ? null : fromJson(map, floorId: floorId);
  }

  final String floorId;
  final PlanBounds? bounds;
  final List<PlanWall> walls;
  final List<PlanColumn> columns;
  final List<PlanOpening> openings;
  final List<PlanSpace> spaces;
  final List<PlanEquipment> equipment;
  final List<ArGridLine> gridLines;
  final List<CornerCandidate> corners;
  final bool fromCache;

  /// The space containing (x, z), or null.
  PlanSpace? spaceAt(double x, double z) {
    for (final s in spaces) {
      if (pointInPolygon(x, z, s.polygon)) return s;
    }
    return null;
  }

  FloorPlan withFromCache(bool fromCache) => FloorPlan(
        floorId: floorId,
        bounds: bounds,
        walls: walls,
        columns: columns,
        openings: openings,
        spaces: spaces,
        equipment: equipment,
        gridLines: gridLines,
        corners: corners,
        fromCache: fromCache,
      );
}

/// Even-odd point-in-polygon test on the floor plane.
bool pointInPolygon(double x, double z, List<Vec2> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i];
    final b = polygon[j];
    if ((a.y > z) != (b.y > z) && x < (b.x - a.x) * (z - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

// ----------------------------------------------------------------- markers

/// A board as `GET /markers` and resolve return it (CONTRACT C6 `Marker`).
class ArMarker {
  const ArMarker({
    required this.code,
    required this.label,
    required this.status,
    required this.accuracyClass,
    this.id,
    this.buildingId,
    this.floorId,
    this.spaceId,
    this.hostGlobalId,
    this.mounting = 'wall',
    this.posTile,
    this.normalTile,
    this.posProject,
    this.heightAboveFloorM,
    this.pairMarkerId,
    this.installNote,
    this.installedAt,
    this.installResidualMm,
    this.lastResidualMm,
    this.confirmations = 0,
    this.lastSeenAt,
  });

  static ArMarker? fromJson(Map<String, dynamic> json) {
    final code = MarkerCode.normalize(_str(json['code']) ?? '');
    if (code == null) return null;
    final pose = json['poseTile'];
    return ArMarker(
      id: _str(json['id']),
      code: code,
      label: _str(json['label']) ?? MarkerCode.display(code),
      buildingId: _str(json['buildingId']),
      floorId: _str(json['floorId']),
      spaceId: _str(json['spaceId']),
      hostGlobalId: _str(json['hostGlobalId']),
      mounting: _str(json['mounting']) ?? 'wall',
      posTile: Vec3.tryParse(json['posTile'] ?? (pose is Map ? pose['p'] : null)),
      normalTile: Vec3.tryParse(json['normalTile'] ?? (pose is Map ? pose['n'] : null)),
      posProject: Vec3.tryParse(json['posProject']),
      heightAboveFloorM: asDouble(json['heightAboveFloorM']),
      accuracyClass: _str(json['accuracyClass']) ?? 'derived',
      status: _str(json['status']) ?? ArMarkerStatus.planned,
      pairMarkerId: _str(json['pairMarkerId']),
      installNote: _str(json['installNote']),
      installedAt: asDate(json['installedAt']),
      installResidualMm: asDouble(json['installResidualMm']),
      lastResidualMm: asDouble(json['lastResidualMm']),
      confirmations: asInt(json['confirmations']) ?? 0,
      lastSeenAt: asDate(json['lastSeenAt']),
    );
  }

  static List<ArMarker> listFromBody(dynamic body) =>
      _rows(body).map(fromJson).whereType<ArMarker>().toList();

  final String? id;
  final String code;
  final String label;
  final String? buildingId;
  final String? floorId;
  final String? spaceId;
  final String? hostGlobalId;
  final String mounting;
  final Vec3? posTile;
  final Vec3? normalTile;
  final Vec3? posProject;
  final double? heightAboveFloorM;
  final String accuracyClass;
  final String status;
  final String? pairMarkerId;
  final String? installNote;
  final DateTime? installedAt;
  final double? installResidualMm;
  final double? lastResidualMm;
  final int confirmations;
  final DateTime? lastSeenAt;

  String get codeDisplay => MarkerCode.display(code);
  bool get isSpare => status == ArMarkerStatus.spare;
  bool get isRetired => status == ArMarkerStatus.retired;

  /// Planned or printed: an installer still has to put it up.
  bool get awaitsInstall =>
      status == ArMarkerStatus.planned || status == ArMarkerStatus.printed;

  /// Usable as an alignment observation (has a pose, not spare or retired).
  bool get usableForAlignment =>
      posTile != null && normalTile != null && !isSpare && !isRetired;

  ManifestMarker? toManifestMarker() {
    if (posTile == null || normalTile == null) return null;
    return ManifestMarker(
      code: code,
      label: label,
      status: status,
      accuracyClass: accuracyClass,
      mounting: mounting,
      posTile: posTile!,
      normalTile: normalTile!,
      sigmaM: ArSigma.forMarkerClass(accuracyClass),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'codeDisplay': codeDisplay,
        'label': label,
        'buildingId': buildingId,
        'floorId': floorId,
        'spaceId': spaceId,
        'hostGlobalId': hostGlobalId,
        'mounting': mounting,
        'posTile': posTile?.toList(),
        'normalTile': normalTile?.toList(),
        'posProject': posProject?.toList(),
        'heightAboveFloorM': heightAboveFloorM,
        'accuracyClass': accuracyClass,
        'status': status,
        'pairMarkerId': pairMarkerId,
        'installNote': installNote,
        'installedAt': installedAt?.toUtc().toIso8601String(),
        'installResidualMm': installResidualMm,
        'lastResidualMm': lastResidualMm,
        'confirmations': confirmations,
        'lastSeenAt': lastSeenAt?.toUtc().toIso8601String(),
      };

  ArMarker copyWith({String? status, DateTime? installedAt, Vec3? posTile, Vec3? normalTile, String? label}) =>
      ArMarker(
        id: id,
        code: code,
        label: label ?? this.label,
        buildingId: buildingId,
        floorId: floorId,
        spaceId: spaceId,
        hostGlobalId: hostGlobalId,
        mounting: mounting,
        posTile: posTile ?? this.posTile,
        normalTile: normalTile ?? this.normalTile,
        posProject: posProject,
        heightAboveFloorM: heightAboveFloorM,
        accuracyClass: accuracyClass,
        status: status ?? this.status,
        pairMarkerId: pairMarkerId,
        installNote: installNote,
        installedAt: installedAt ?? this.installedAt,
        installResidualMm: installResidualMm,
        lastResidualMm: lastResidualMm,
        confirmations: confirmations,
        lastSeenAt: lastSeenAt,
      );
}

class ArNamedRef {
  const ArNamedRef({required this.id, required this.name});

  static ArNamedRef? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final id = _str(raw['id']);
    if (id == null) return null;
    return ArNamedRef(id: id, name: _str(raw['name']) ?? '');
  }

  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
}

/// `GET /markers/resolve/:code` — one scan decides building, floor and model.
class MarkerResolution {
  const MarkerResolution({
    required this.marker,
    required this.building,
    required this.floor,
    this.builds = const [],
    this.manifestUrl,
    this.focusBytes = 0,
    this.totalBytes = 0,
    this.badges = const [],
    this.fromCache = false,
    this.packOnDevice = false,
  });

  static MarkerResolution? fromJson(Map<String, dynamic> json) {
    final markerJson = json['marker'];
    final marker = markerJson is Map ? ArMarker.fromJson(Map<String, dynamic>.from(markerJson)) : null;
    final building = ArNamedRef.fromJson(json['building']);
    final floor = ArNamedRef.fromJson(json['floor']);
    if (marker == null || building == null || floor == null) return null;
    final manifest = json['manifest'];
    return MarkerResolution(
      marker: marker,
      building: building,
      floor: floor,
      builds: _maps(json['builds']).map(ArBuildRef.fromJson).whereType<ArBuildRef>().toList(),
      manifestUrl: manifest is Map ? _str(manifest['url']) : null,
      focusBytes: manifest is Map ? asInt(manifest['focusBytes']) ?? 0 : 0,
      totalBytes: manifest is Map ? asInt(manifest['totalBytes']) ?? 0 : 0,
      badges: _strings(json['badges']),
    );
  }

  static MarkerResolution? fromBody(dynamic body) {
    final map = unwrapMap(body);
    return map.isEmpty ? null : fromJson(map);
  }

  final ArMarker marker;
  final ArNamedRef building;
  final ArNamedRef floor;
  final List<ArBuildRef> builds;
  final String? manifestUrl;
  final int focusBytes;
  final int totalBytes;

  /// e.g. `model-older-than-upload`, `checked-in-elsewhere`.
  final List<String> badges;

  /// Local: resolved from the phone's own floor pack, no signal needed.
  final bool fromCache;

  /// Local: this floor's pack is already downloaded ("Model is on this phone").
  final bool packOnDevice;

  MarkerResolution copyWith({bool? fromCache, bool? packOnDevice}) => MarkerResolution(
        marker: marker,
        building: building,
        floor: floor,
        builds: builds,
        manifestUrl: manifestUrl,
        focusBytes: focusBytes,
        totalBytes: totalBytes,
        badges: badges,
        fromCache: fromCache ?? this.fromCache,
        packOnDevice: packOnDevice ?? this.packOnDevice,
      );
}

/// Resolve error codes (CONTRACT C6).
abstract final class ArErrorCode {
  static const unknownCode = 'UNKNOWN_CODE';
  static const noAccess = 'NO_ACCESS';
  static const retired = 'RETIRED';
  static const spareUnbound = 'SPARE_UNBOUND';
  static const noPublishedBuild = 'NO_PUBLISHED_BUILD';
  static const alreadyBound = 'ALREADY_BOUND';

  /// Client-side: the code failed its check character (never sent).
  static const notAMarker = 'NOT_A_MARKER';

  /// Client-side: not on the phone and no signal to ask the server.
  static const needsSignal = 'NEEDS_SIGNAL';
}

class NearestMarker {
  const NearestMarker({required this.code, required this.label, this.distanceM});

  static NearestMarker? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final code = _str(raw['code']);
    if (code == null) return null;
    return NearestMarker(
      code: MarkerCode.normalize(code) ?? code,
      label: _str(raw['label']) ?? code,
      distanceM: asDouble(raw['distanceM']),
    );
  }

  final String code;
  final String label;
  final double? distanceM;
}

/// A failed AR call, with the server's `{message, code}` (and, for a retired
/// board, the nearest active one: "The nearest active board is L03-M06, 4 m
/// west"). Every error has a next step; [code] picks it.
class ArApiError implements Exception {
  const ArApiError({required this.code, required this.message, this.status, this.nearest});

  /// From an HTTP error body in any envelope shape.
  factory ArApiError.fromBody(int status, dynamic body, {String? fallbackMessage}) {
    final map = body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};
    final inner = map['data'] is Map ? Map<String, dynamic>.from(map['data'] as Map) : map;
    final code = _str(map['code']) ?? _str(inner['code']) ?? _codeForStatus(status);
    return ArApiError(
      status: status,
      code: code,
      message: _str(map['message']) ?? _str(inner['message']) ?? fallbackMessage ?? code,
      nearest: NearestMarker.fromJson(map['nearest'] ?? inner['nearest'] ?? map['nearestActive'] ?? inner['nearestActive']),
    );
  }

  static String _codeForStatus(int status) => switch (status) {
        404 => ArErrorCode.unknownCode,
        403 => ArErrorCode.noAccess,
        410 => ArErrorCode.retired,
        _ => 'HTTP_$status',
      };

  final String code;
  final String message;
  final int? status;
  final NearestMarker? nearest;

  @override
  String toString() => 'ArApiError($code, $status): $message';
}

// ---------------------------------------------------------------- progress

abstract final class ArProgressStatus {
  static const notStarted = 'not_started';
  static const installed = 'installed';
  static const verified = 'verified';
  static const issue = 'issue';

  static const values = [notStarted, installed, verified, issue];
}

/// One element's installation status (four-eyes progress, AR-50).
class ElementProgress {
  const ElementProgress({
    required this.globalId,
    required this.status,
    this.assetId,
    this.installedBy,
    this.installedAt,
    this.verifiedBy,
    this.verifiedAt,
    this.note,
    this.pending = false,
  });

  static ElementProgress? fromJson(Map<String, dynamic> json) {
    final id = _str(json['globalId']);
    if (id == null) return null;
    return ElementProgress(
      globalId: id,
      status: _str(json['status']) ?? ArProgressStatus.notStarted,
      assetId: _str(json['assetId']),
      installedBy: _str(json['installedBy']),
      installedAt: asDate(json['installedAt']),
      verifiedBy: _str(json['verifiedBy']),
      verifiedAt: asDate(json['verifiedAt']),
      note: _str(json['note']),
      pending: asBool(json['pending']) ?? false,
    );
  }

  final String globalId;
  final String status;
  final String? assetId;
  final String? installedBy;
  final DateTime? installedAt;
  final String? verifiedBy;
  final DateTime? verifiedAt;
  final String? note;

  /// Local: set on this phone and still waiting in the offline queue.
  final bool pending;

  Map<String, dynamic> toJson() => {
        'globalId': globalId,
        'status': status,
        'assetId': assetId,
        'installedBy': installedBy,
        'installedAt': installedAt?.toUtc().toIso8601String(),
        'verifiedBy': verifiedBy,
        'verifiedAt': verifiedAt?.toUtc().toIso8601String(),
        'note': note,
        'pending': pending,
      };

  /// The status after [to] is applied locally by [actorId], before the
  /// server has confirmed it.
  ElementProgress applied(String to, {String? actorId, String? note, DateTime? at}) {
    final now = at ?? DateTime.now();
    return ElementProgress(
      globalId: globalId,
      status: to,
      assetId: assetId,
      installedBy: to == ArProgressStatus.installed ? actorId : installedBy,
      installedAt: to == ArProgressStatus.installed ? now : installedAt,
      verifiedBy: to == ArProgressStatus.verified ? actorId : verifiedBy,
      verifiedAt: to == ArProgressStatus.verified ? now : verifiedAt,
      note: note ?? this.note,
      pending: true,
    );
  }
}

class ProgressSummary {
  const ProgressSummary({
    this.total = 0,
    this.installed = 0,
    this.verified = 0,
    this.issue = 0,
  });

  static ProgressSummary fromJson(dynamic raw) {
    if (raw is! Map) return const ProgressSummary();
    return ProgressSummary(
      total: asInt(raw['total']) ?? 0,
      installed: asInt(raw['installed']) ?? 0,
      verified: asInt(raw['verified']) ?? 0,
      issue: asInt(raw['issue']) ?? 0,
    );
  }

  /// Counted from rows, for the offline copy (and after a local change).
  /// [total] defaults to the number of rows.
  factory ProgressSummary.of(List<ElementProgress> rows, {int? total}) {
    var installed = 0, verified = 0, issue = 0;
    for (final r in rows) {
      switch (r.status) {
        case ArProgressStatus.installed:
          installed++;
        case ArProgressStatus.verified:
          verified++;
        case ArProgressStatus.issue:
          issue++;
      }
    }
    return ProgressSummary(
      total: math.max(total ?? rows.length, rows.length),
      installed: installed,
      verified: verified,
      issue: issue,
    );
  }

  final int total;
  final int installed;
  final int verified;
  final int issue;

  /// Share installed-or-verified, 0–1: the legend's headline percentage.
  double get doneShare => total == 0 ? 0 : (installed + verified) / total;
  double get verifiedShare => total == 0 ? 0 : verified / total;
}

class FloorProgress {
  const FloorProgress({
    required this.floorId,
    this.statuses = const [],
    this.summary = const ProgressSummary(),
    this.fromCache = false,
  });

  static FloorProgress fromBody(String floorId, dynamic body) {
    final map = unwrapMap(body);
    final rows = _maps(map['statuses']).map(ElementProgress.fromJson).whereType<ElementProgress>().toList();
    return FloorProgress(
      floorId: floorId,
      statuses: rows,
      summary: map['summary'] is Map ? ProgressSummary.fromJson(map['summary']) : ProgressSummary.of(rows),
    );
  }

  final String floorId;
  final List<ElementProgress> statuses;
  final ProgressSummary summary;
  final bool fromCache;

  Map<String, ElementProgress> get byGlobalId => {for (final s in statuses) s.globalId: s};
}

abstract final class ProgressRejectReason {
  static const secondPersonRequired = 'SECOND_PERSON_REQUIRED';
  static const notInstalled = 'NOT_INSTALLED';
}

class ProgressRejection {
  const ProgressRejection({required this.globalId, required this.reason});

  final String globalId;

  /// [ProgressRejectReason] values.
  final String reason;
}

class ProgressUpdateResult {
  const ProgressUpdateResult({
    required this.updated,
    this.rejected = const [],
    this.queued = false,
  });

  static ProgressUpdateResult fromBody(dynamic body) {
    final map = unwrapMap(body);
    return ProgressUpdateResult(
      updated: asInt(map['updated']) ?? 0,
      rejected: [
        for (final r in _maps(map['rejected']))
          if (_str(r['globalId']) != null)
            ProgressRejection(globalId: _str(r['globalId'])!, reason: _str(r['reason']) ?? ''),
      ],
    );
  }

  final int updated;
  final List<ProgressRejection> rejected;

  /// True when the write is parked in the offline queue: the server hasn't
  /// ruled on four-eyes yet.
  final bool queued;
}

/// The server's four-eyes rule, checked on the phone first so the user is
/// told *before* a queued write is refused later (UX only; the server
/// decides, like the close-flow checks).
abstract final class ProgressRules {
  /// The reason [to] would be refused for [current] by [actorId], or null.
  static String? precheck(ElementProgress? current, String to, String? actorId) {
    if (to != ArProgressStatus.verified) return null;
    if (current == null || current.status != ArProgressStatus.installed) {
      return current?.status == ArProgressStatus.verified ? null : ProgressRejectReason.notInstalled;
    }
    if (actorId != null && current.installedBy == actorId) {
      return ProgressRejectReason.secondPersonRequired;
    }
    return null;
  }
}

// --------------------------------------------------------- alignment events

class ArObservationSummary {
  const ArObservationSummary({required this.kind, required this.ref, required this.residualMm, this.posTile});

  /// `marker | corner`.
  final String kind;

  /// Marker code or corner id.
  final String ref;
  final double residualMm;

  /// Where this session's fit puts the board, in the tile frame
  /// (`inverse(arFromTile) × anchor`). Markers only. Marker Health takes the
  /// median of these across sessions to suggest the new position of a board
  /// that was knocked or re-stuck ("Adopt the new position"); without it that
  /// suggestion stays null.
  final List<double>? posTile;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'ref': ref,
        'residualMm': residualMm,
        if (posTile != null) 'posTile': posTile,
      };
}

/// One AR session's alignment record (`POST /alignment-events`), the input
/// to marker health and promotion.
class ArAlignmentEvent {
  const ArAlignmentEvent({
    required this.buildingId,
    required this.floorId,
    required this.buildIds,
    required this.observations,
    required this.maxResidualMm,
    required this.method,
    required this.quality,
    required this.distanceWalkedM,
    required this.deviceTier,
    required this.capturedAt,
  });

  /// From a fit and the observations it was given. Outliers are included
  /// with their residuals: a board that moved is exactly what health needs
  /// to hear about.
  factory ArAlignmentEvent.fromFit({
    required String buildingId,
    required String floorId,
    required List<String> buildIds,
    required AlignmentFit fit,
    required List<ArObservation> observations,
    required double distanceWalkedM,
    required String deviceTier,
    DateTime? capturedAt,
  }) =>
      ArAlignmentEvent(
        buildingId: buildingId,
        floorId: floorId,
        buildIds: buildIds,
        observations: [
          for (final o in observations)
            ArObservationSummary(
              kind: o.kind,
              ref: o.id,
              residualMm: ((fit.residualsM[o.id] ?? 0.0) * 10000).roundToDouble() / 10,
            ),
        ],
        maxResidualMm: (fit.maxResidualMm * 10).roundToDouble() / 10,
        method: fit.method,
        quality: fit.quality.name,
        distanceWalkedM: distanceWalkedM,
        deviceTier: deviceTier,
        capturedAt: capturedAt ?? DateTime.now(),
      );

  final String buildingId;
  final String floorId;
  final List<String> buildIds;
  final List<ArObservationSummary> observations;
  final double maxResidualMm;
  final String method;

  /// [AlignmentQuality] name.
  final String quality;
  final double distanceWalkedM;
  final String deviceTier;
  final DateTime capturedAt;

  Map<String, dynamic> toJson() => {
        'buildingId': buildingId,
        'floorId': floorId,
        'buildIds': buildIds,
        'observations': [for (final o in observations) o.toJson()],
        'maxResidualMm': maxResidualMm,
        'method': method,
        'quality': quality,
        'distanceWalkedM': distanceWalkedM,
        'deviceTier': deviceTier,
        'capturedAt': capturedAt.toUtc().toIso8601String(),
      };
}
