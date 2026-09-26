import 'dart:math' as math;

import '../core/ar/corner_matcher.dart' show CornerCandidate;
import '../core/ar/vec.dart';
import 'ar_engine_bridge.dart' show ArTile;

/// What the AR screens render, kept separate from the wire models in
/// `domain/ar_models.dart` on purpose. The screens were written in parallel
/// with the repository (contract v1, 2026-09-26), so every screen depends on
/// these small UI shapes and on [ArGateway] only; `ar_gateway_live.dart` is
/// the one file that maps the repository's models onto them. A wire-shape
/// change is then a one-file fix, never a hunt through a dozen screens.
///
/// All positions are in the **tile frame** (building-local, Y up, metres,
/// contract C2). Plan coordinates are the tile frame's XZ, drawn with x to
/// the right and z downward, like the web plan.

/// `ready | building | failed | no-ifc` from `GET /buildings/:id/floors`.
enum ArModelState {
  ready,
  building,
  failed,
  noIfc;

  static ArModelState parse(String? wire) => switch (wire) {
    'ready' => ArModelState.ready,
    'building' => ArModelState.building,
    'failed' => ArModelState.failed,
    _ => ArModelState.noIfc,
  };
}

class ArBuildingRef {
  const ArBuildingRef({required this.id, required this.name});
  final String id;
  final String name;
}

/// One model lineage on a floor (architecture, MEP, structure…), with what
/// this phone already holds of its current build.
class ArModelEntry {
  const ArModelEntry({
    required this.lineage,
    required this.modelName,
    required this.state,
    this.buildId,
    this.version,
    this.publishedAt,
    this.bytes = 0,
    this.onDeviceBytes = 0,
    this.changedTiles = 0,
    this.reason,
    this.onDevice = false,
    this.updateAvailable = false,
  });

  final String lineage;
  final String modelName;
  final ArModelState state;
  final String? buildId;
  final int? version;
  final DateTime? publishedAt;
  final int bytes;

  /// Bytes of this build already in the local tile store. Tiles are content
  /// addressed, so an unchanged cell from the previous build counts too.
  final int onDeviceBytes;

  /// Tiles that differ from what is on the phone ("3 tiles changed").
  final int changedTiles;

  /// Why the model can't be used ("Source IFC missing"), from the server.
  final String? reason;

  /// The current build is complete on this phone.
  final bool onDevice;

  /// An older build of this model is on the phone; the current one isn't.
  final bool updateAvailable;

  bool get usable => state == ArModelState.ready && buildId != null;
  int get missingBytes => math.max(0, bytes - onDeviceBytes);
  bool get fullyOnDevice => usable && (onDevice || (bytes > 0 && missingBytes == 0));

  /// A coarse discipline from the lineage/model name, for the icon and the
  /// default tick (architecture + MEP are what most jobs need).
  String get discipline {
    final n = '$lineage $modelName'.toLowerCase();
    if (n.contains('fire') || n.contains('sprinkler')) return 'fire';
    if (n.contains('mep') || n.contains('mech') || n.contains('hvac') || n.contains('plumb') || n.contains('elec')) {
      return 'mep';
    }
    if (n.contains('struct')) return 'structure';
    return 'architecture';
  }
}

class ArFloorSummary {
  const ArFloorSummary({
    required this.floorId,
    required this.name,
    this.elevation,
    this.models = const [],
    this.markerCount = 0,
    this.cornerCount = 0,
    this.gridNames = const [],
  });

  final String floorId;
  final String name;
  final double? elevation;
  final List<ArModelEntry> models;
  final int markerCount;
  final int cornerCount;
  final List<String> gridNames;

  bool get hasUsableModel => models.any((m) => m.usable);

  /// "A–C · 1–2" from the grid names: letters and numbers ranged separately.
  String get gridSummary {
    final letters = gridNames.where((n) => n.isNotEmpty && !_isNumeric(n)).toList()..sort();
    final numbers = gridNames.where(_isNumeric).toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    String range(List<String> xs) => xs.isEmpty ? '' : (xs.length == 1 ? xs.first : '${xs.first}–${xs.last}');
    return [range(letters), range(numbers)].where((s) => s.isNotEmpty).join(' · ');
  }

  static bool _isNumeric(String s) => int.tryParse(s) != null;
}

class ArBuildRef {
  const ArBuildRef({
    required this.buildId,
    required this.lineage,
    required this.modelName,
    this.version,
    this.publishedAt,
  });

  final String buildId;
  final String lineage;
  final String modelName;
  final int? version;
  final DateTime? publishedAt;
}

/// A board as the technician screens need it (manifest `markers[]` or a
/// resolve `marker`). [code] is the canonical 7-char form.
class ArMarkerInfo {
  const ArMarkerInfo({
    required this.code,
    required this.label,
    required this.status,
    required this.accuracyClass,
    required this.posTile,
    required this.normalTile,
    this.mounting = 'wall',
    this.sigmaM,
    this.floorId,
    this.locationText,
    this.heightAboveFloorM,
    this.installNote,
  });

  final String code;
  final String label;

  /// spare | planned | printed | installed | active | suspect | needs-review | retired
  final String status;

  /// surveyed | feature | derived
  final String accuracyClass;
  final String mounting;
  final Vec3 posTile;
  final Vec3 normalTile;
  final double? sigmaM;
  final String? floorId;

  /// "Plant Room B · east wall", when the server knows it.
  final String? locationText;
  final double? heightAboveFloorM;
  final String? installNote;

  bool get isSpare => status == 'spare';
  bool get isRetired => status == 'retired';

  /// Boards that can anchor an alignment today.
  bool get usableForAlignment =>
      status == 'active' || status == 'installed' || status == 'suspect' || status == 'needs-review';

  /// Contract C2: surveyed 5 mm, feature 20 mm, derived 30 mm, unless the
  /// server sent its own sigma.
  double get classSigmaM =>
      sigmaM ??
      switch (accuracyClass) {
        'surveyed' => 0.005,
        'derived' => 0.03,
        _ => 0.02,
      };
}

class ArGridLine {
  const ArGridLine({required this.name, required this.p0, required this.p1});
  final String name;

  /// Plan points (tile x, tile z).
  final Vec2 p0;
  final Vec2 p1;
}

/// One modelled element (a row of `GET /features/:buildId`).
class ArFeature {
  const ArFeature({
    required this.buildId,
    required this.featureId,
    required this.globalId,
    required this.discipline,
    required this.ifcType,
    required this.bboxMin,
    required this.bboxMax,
    this.assetId,
    this.name,
    this.systemGlobalId,
    this.systemName,
    this.floorId,
    this.tileHashes = const {},
    this.props = const {},
  });

  final String buildId;
  final int featureId;
  final String globalId;
  final String? assetId;
  final String? name;
  final String discipline;
  final String? systemGlobalId;

  /// A readable system name when known ("CHW supply"); the server sends only
  /// the system's GlobalId, so the demo data and a later server field fill it.
  final String? systemName;
  final String ifcType;
  final Vec3 bboxMin;
  final Vec3 bboxMax;
  final String? floorId;

  /// Tiles this element appears in: pinned resident while it is the target.
  final Set<String> tileHashes;

  /// IFC instance properties (`"<Pset>.<Property>": text`, plus `Tag`).
  final Map<String, String> props;

  /// The first property named [name] in any property set, case-insensitive.
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

  Vec3 get centre => Vec3(
    (bboxMin.x + bboxMax.x) / 2,
    (bboxMin.y + bboxMax.y) / 2,
    (bboxMin.z + bboxMax.z) / 2,
  );

  /// The longest bounding-box side: a pipe or duct run's length, near enough
  /// for "42.6 m of pipe" (runs are modelled as straight segments).
  double get extentM => math.max(
    (bboxMax.x - bboxMin.x).abs(),
    math.max((bboxMax.y - bboxMin.y).abs(), (bboxMax.z - bboxMin.z).abs()),
  );

  bool get isRun {
    final t = ifcType.toLowerCase();
    return t.contains('pipe') || t.contains('duct') || t.contains('cable') || t.contains('segment');
  }

  bool get isValve => ifcType.toLowerCase().contains('valve');

  String get displayName => (name == null || name!.trim().isEmpty) ? ifcType : name!;
}

/// What `ArEngine.pick` hit.
class ArPickHit {
  const ArPickHit({required this.featureId, this.buildId, this.hitTile, this.distanceM});
  final int featureId;
  final String? buildId;
  final Vec3? hitTile;
  final double? distanceM;
}

/// A pin to draw in the scene: the ghost board, a snag, the next board.
class ArPinSpec {
  const ArPinSpec({required this.id, required this.posTile, required this.kind, this.label, this.normalTile});
  final String id;
  final Vec3 posTile;

  /// `ghostBoard | snag | board | target`.
  final String kind;
  final String? label;
  final Vec3? normalTile;
}

class ArPlanSpace {
  const ArPlanSpace({required this.name, required this.polygon, required this.labelAt, this.spaceId});
  final String? spaceId;
  final String name;
  final List<Vec2> polygon;
  final Vec2 labelAt;
}

class ArPlanEquipment {
  const ArPlanEquipment({required this.name, required this.polygon, this.globalId, this.assetId});
  final String name;
  final List<Vec2> polygon;
  final String? globalId;
  final String? assetId;
}

/// `GET /floors/:floorId/plan`, reduced to what the mini plan draws.
class ArPlan {
  const ArPlan({
    required this.minX,
    required this.minZ,
    required this.maxX,
    required this.maxZ,
    this.walls = const [],
    this.wallThicknesses = const [],
    this.columns = const [],
    this.doors = const [],
    this.spaces = const [],
    this.equipment = const [],
  });

  final double minX;
  final double minZ;
  final double maxX;
  final double maxZ;

  /// Wall centre lines.
  final List<List<Vec2>> walls;

  /// Thickness of `walls[i]` in metres, parallel to [walls]. The mini plan
  /// draws hairlines and never needed it; the drill check and "concealed in
  /// wall" do (a wall's faces are its centre line ± thickness/2). Plans
  /// built without it read the server's own default via [wallThicknessAt].
  final List<double> wallThicknesses;
  final List<List<Vec2>> columns;

  /// Door openings as two-point segments.
  final List<List<Vec2>> doors;
  final List<ArPlanSpace> spaces;
  final List<ArPlanEquipment> equipment;

  double get width => math.max(0.1, maxX - minX);
  double get depth => math.max(0.1, maxZ - minZ);

  /// 0.2 m (the wire parser's default, `PlanWall.thickness`) when unknown.
  double wallThicknessAt(int i) => i < wallThicknesses.length && wallThicknesses[i] > 0 ? wallThicknesses[i] : 0.2;

  /// The space whose polygon contains the plan point, if any.
  ArPlanSpace? spaceAt(double x, double z) {
    for (final s in spaces) {
      if (_contains(s.polygon, x, z)) return s;
    }
    return null;
  }

  static bool _contains(List<Vec2> poly, double x, double z) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final a = poly[i];
      final b = poly[j];
      if ((a.y > z) != (b.y > z) && x < (b.x - a.x) * (z - a.y) / ((b.y - a.y) == 0 ? 1e-9 : (b.y - a.y)) + a.x) {
        inside = !inside;
      }
    }
    return inside;
  }
}

/// Everything a session needs about one floor: the manifest, mapped.
class ArFloorContext {
  const ArFloorContext({
    required this.buildingId,
    required this.buildingName,
    required this.floorId,
    required this.floorName,
    required this.builds,
    required this.tiles,
    required this.markers,
    required this.corners,
    required this.gridLines,
    this.floorFinishOffsetM = 0,
    this.floorDatumY = 0,
    this.totalBytes = 0,
    this.focusBytes = 0,
    this.fromCache = false,
  });

  final String buildingId;
  final String buildingName;
  final String floorId;
  final String floorName;
  final List<ArBuildRef> builds;

  /// Opaque manifest tiles, handed straight to `TileResidency` and the
  /// download service; the UI only reads their size through the bridge.
  final List<ArTile> tiles;
  final List<ArMarkerInfo> markers;
  final List<CornerCandidate> corners;
  final List<ArGridLine> gridLines;
  final double floorFinishOffsetM;

  /// The finished-floor height in the tile frame (corner `pos.y` = datum).
  final double floorDatumY;
  final int totalBytes;
  final int focusBytes;
  final bool fromCache;

  List<ArMarkerInfo> get activeMarkers => markers.where((m) => m.usableForAlignment).toList();

  ArMarkerInfo? markerByCode(String code) {
    for (final m in markers) {
      if (m.code == code) return m;
    }
    return null;
  }

  ArBuildRef? buildFor(String buildId) {
    for (final b in builds) {
      if (b.buildId == buildId) return b;
    }
    return null;
  }

  /// The build new boards are stored against: architecture first (walls
  /// carry boards), else whatever is loaded.
  String? get primaryBuildId {
    for (final b in builds) {
      if ('${b.lineage} ${b.modelName}'.toLowerCase().contains('arch')) return b.buildId;
    }
    return builds.isEmpty ? null : builds.first.buildId;
  }
}

sealed class ArResolveResult {
  const ArResolveResult();
}

class ArResolved extends ArResolveResult {
  const ArResolved({
    required this.marker,
    required this.building,
    required this.floorId,
    required this.floorName,
    required this.builds,
    this.focusBytes = 0,
    this.totalBytes = 0,
    this.onDeviceBytes = 0,
    this.badges = const [],
    this.fromCache = false,
  });

  final ArMarkerInfo marker;
  final ArBuildingRef building;
  final String floorId;
  final String floorName;
  final List<ArBuildRef> builds;
  final int focusBytes;
  final int totalBytes;
  final int onDeviceBytes;

  /// Server badges, e.g. `older-build` ("Model is older than the latest upload").
  final List<String> badges;

  /// Resolved from the downloaded floor pack, no signal used.
  final bool fromCache;

  bool get onDevice => totalBytes > 0 && onDeviceBytes >= totalBytes;
}

/// Every §3.3 error, with the next step the screen offers.
class ArResolveFailed extends ArResolveResult {
  const ArResolveFailed({
    required this.code,
    this.nearestCode,
    this.nearestLabel,
    this.nearestDistanceM,
    this.retiredAt,
    this.buildingName,
    this.message,
  });

  /// UNKNOWN_CODE | NO_ACCESS | RETIRED | SPARE_UNBOUND | NO_PUBLISHED_BUILD |
  /// OFFLINE | NOT_A_MARKER | ERROR
  final String code;
  final String? nearestCode;
  final String? nearestLabel;
  final double? nearestDistanceM;
  final DateTime? retiredAt;
  final String? buildingName;
  final String? message;
}

/// `not_started | installed | verified | issue`.
enum ArProgressStatus {
  notStarted('not_started'),
  installed('installed'),
  verified('verified'),
  issue('issue');

  const ArProgressStatus(this.wire);
  final String wire;

  static ArProgressStatus parse(String? wire) {
    for (final s in values) {
      if (s.wire == wire) return s;
    }
    return ArProgressStatus.notStarted;
  }
}

class ArProgressEntry {
  const ArProgressEntry({
    required this.globalId,
    required this.status,
    this.assetId,
    this.installedBy,
    this.installedAt,
    this.verifiedBy,
    this.verifiedAt,
    this.note,
  });

  final String globalId;
  final ArProgressStatus status;
  final String? assetId;
  final String? installedBy;
  final DateTime? installedAt;
  final String? verifiedBy;
  final DateTime? verifiedAt;
  final String? note;
}

class ArProgressSnapshot {
  const ArProgressSnapshot({
    this.entries = const {},
    this.total = 0,
    this.installed = 0,
    this.verified = 0,
    this.issue = 0,
  });

  /// By GlobalId.
  final Map<String, ArProgressEntry> entries;
  final int total;
  final int installed;
  final int verified;
  final int issue;

  /// "Installed 64%" counts verified elements too: they were installed first.
  double get installedShare => total == 0 ? 0 : (installed + verified) / total;
  double get verifiedShare => total == 0 ? 0 : verified / total;

  ArProgressStatus statusOf(String globalId) => entries[globalId]?.status ?? ArProgressStatus.notStarted;
}

class ArProgressRejection {
  const ArProgressRejection({required this.globalId, required this.reason});
  final String globalId;

  /// SECOND_PERSON_REQUIRED | NOT_INSTALLED
  final String reason;
}

class ArProgressWriteResult {
  const ArProgressWriteResult({this.updated = 0, this.rejected = const [], this.queued = false, this.errorCode});
  final int updated;
  final List<ArProgressRejection> rejected;

  /// Parked in the offline queue; the server decides four-eyes on replay.
  final bool queued;
  final String? errorCode;
}

/// Outcome of a marker write (bind a spare, confirm an install).
class ArWriteResult {
  const ArWriteResult({this.synced = false, this.queued = false, this.errorCode, this.message, this.marker});
  final bool synced;
  final bool queued;

  /// ALREADY_BOUND, NO_PUBLISHED_BUILD… or null.
  final String? errorCode;
  final String? message;
  final ArMarkerInfo? marker;

  bool get ok => synced || queued;
}

class ArDownloadProgress {
  const ArDownloadProgress({
    this.focusDoneBytes = 0,
    this.focusTotalBytes = 0,
    this.doneBytes = 0,
    this.totalBytes = 0,
    this.done = false,
    this.error,
  });

  final int focusDoneBytes;
  final int focusTotalBytes;
  final int doneBytes;
  final int totalBytes;
  final bool done;
  final String? error;

  bool get focusReady => focusTotalBytes == 0 || focusDoneBytes >= focusTotalBytes;
  double get fraction => totalBytes == 0 ? (done ? 1 : 0) : (doneBytes / totalBytes).clamp(0, 1).toDouble();
  int get restBytes => math.max(0, totalBytes - focusTotalBytes);
  int get restDoneBytes => math.max(0, doneBytes - focusDoneBytes);
}

/// What an AR session reports to `POST /alignment-events`.
class ArAlignmentReport {
  const ArAlignmentReport({
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

  final String buildingId;
  final String floorId;
  final List<String> buildIds;

  /// `{kind: marker|corner, ref, residualMm}`.
  final List<Map<String, Object?>> observations;
  final double maxResidualMm;
  final String method;
  final String quality;
  final double distanceWalkedM;
  final String deviceTier;
  final DateTime capturedAt;

  Map<String, Object?> toJson() => {
    'buildingId': buildingId,
    'floorId': floorId,
    'buildIds': buildIds,
    'observations': observations,
    'maxResidualMm': maxResidualMm,
    'method': method,
    'quality': quality,
    'distanceWalkedM': distanceWalkedM,
    'deviceTier': deviceTier,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
  };
}

/// The installer's self-check, as recorded with `confirm-install`.
class ArInstallChecks {
  const ArInstallChecks({required this.code, this.scalePct, this.positionM, this.tiltDeg});
  final bool code;
  final double? scalePct;
  final double? positionM;
  final double? tiltDeg;

  Map<String, Object?> toJson() => {
    'code': code,
    'scalePct': ?scalePct,
    'positionM': ?positionM,
    'tiltDeg': ?tiltDeg,
  };
}
