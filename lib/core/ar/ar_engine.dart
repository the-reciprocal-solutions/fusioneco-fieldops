import 'dart:math' as math;
import 'dart:typed_data';

import '../network/envelope.dart';
import 'vec.dart';

/// The seam between Flutter and the native AR engine (docs/ar-bim-overlay.md
/// §6.4, CONTRACT C8). **Native executes, Dart decides**: the engine owns the
/// camera, tracking, detection, hit-tests, drawing and picking; every
/// decision (which observation to trust, where the model goes, which tiles
/// are resident, what is highlighted) is made in pure Dart and pushed down
/// through these commands.
///
/// Implementations: [ChannelArEngine] (the `packages/fe_ar` plugin over
/// `fusioneco/ar`) and [FakeArEngine] (tests and the in-app Demo mode).
abstract interface class ArEngine {
  /// Called before AR is offered at all. Never throws: a missing plugin
  /// reports `supported: false, reason: 'engine-not-installed'`.
  Future<ArCapabilities> capabilities();

  /// [recordTo] / [playbackFrom] (debug builds only, `docs/ar-recording-playback.md`):
  /// record this session to an MP4 (ARCore Recording & Playback), or run it
  /// from one instead of the camera, so one room can be replayed at a desk.
  /// iOS answers with `recording-unsupported` / `playback-unsupported` errors.
  Future<void> startSession({String? recordTo, String? playbackFrom});

  /// Tiles by content hash and local file path (`<appSupport>/ar/tiles/<hash>.glb`).
  /// Answers once every tile is decoded, with what native actually holds
  /// (CHANNEL.md `{loaded, failed}`): a tile that failed, or was unloaded
  /// (`stop`) while it was still loading, is not resident and must be asked
  /// for again.
  Future<TileLoadResult> loadTiles(List<TileRef> tiles);

  Future<void> unloadTiles(List<String> hashes);

  /// The fitted model → AR-world transform. Native never computes it; it
  /// only eases to it (never snaps). Since CHANNEL.md revision 2 it may carry
  /// a scale ("Place by hand": uniform, or stretched along the model's X/Z):
  /// such a matrix applies at once (no easing), and native picking and the
  /// section plane account for it.
  Future<void> setModelTransform(Mat4 arFromTile, {int easeMs = 300});

  /// The feature-state texture (`feature_state.dart`): one RGBA texel per
  /// feature id, [width] texels per row.
  ///
  /// [buildId] scopes the texture to one build. Feature ids are dense *per
  /// build* (CONTRACT C4), so with architecture and MEP both on a floor id 12
  /// names two different elements; without [buildId] the native side applies
  /// the texture to every build that has none of its own, which hides or
  /// tints the other build's namesakes too. Send one texture per build.
  /// (Additive to C8; `packages/fe_ar` CHANNEL.md already reads `buildId`.)
  Future<void> setFeatureState(Uint8List rgba, int width, {String? buildId});

  Future<void> setLayers(LayerState s);

  /// X-ray drawing and `targetScreen` events for these features; null clears.
  /// [buildId] names the build the ids belong to — without it the native
  /// side unions the bounds of every build's feature with that id, and the
  /// off-screen arrow points at the wrong place. (Additive to C8.)
  Future<void> setTarget(List<int>? featureIds, {String? buildId});

  /// Structural grid lines drawn on the floor at [floorY] (tile frame), as
  /// an alignment guide and a snap target.
  Future<void> setGridLines(List<GridLineRef> lines, double floorY);

  /// Snag, finding and ghost-board pins, in the tile frame.
  Future<void> setPins(List<ArPin> pins);

  /// Snaps a corner under screen point ([x], [y]) in logical pixels.
  Future<CornerSeenEvent?> detectCornerAt(double x, double y);

  /// Pins a native anchor at [posAr] (fe_ar extension) and returns its id; the
  /// engine then sends `anchor` events as the tracker refines it, exactly as
  /// for a board. Used for committed corner snaps, so the model follows
  /// ARCore/ARKit map corrections instead of sliding. Null if unsupported.
  Future<String?> anchorAt(Vec3 posAr);

  /// The feature under a screen point, against resident tiles.
  Future<PickResult?> pick(double x, double y);

  /// [pick] for many screen points in one call (fe_ar extension `pickMany`),
  /// for the lasso: one result per point, in order, null where nothing is
  /// hit. An engine without the extension answers with sequential picks.
  Future<List<PickResult?>> pickMany(List<(double, double)> points);

  /// Tile-frame points → view logical pixels through the current (eased)
  /// model transform (fe_ar extension `projectTile`): `(x, y, onScreen)`
  /// per point, null where it can't be placed. Drives the Flutter-drawn
  /// floating labels. Empty answers from an engine without the extension.
  Future<List<(double, double, bool)?>> projectTile(List<Vec3> pointsTile);

  /// The measured surface point under a screen point (fe_ar extension
  /// `depthPointAt`): ARCore Raw Depth where its confidence is high, else a
  /// tracked plane, else smoothed depth. Feeds the wall-taps corner
  /// (`wall_fit.dart`) and the long-baseline heading tap. Null when nothing
  /// trustworthy is under the point, or the engine lacks the extension.
  Future<ArDepthPoint?> depthPointAt(double x, double y);

  /// World rays through view points in logical pixels (fe_ar extension
  /// `rayAt`), one per point, null where the camera isn't known yet. "Place
  /// by hand" drags the model along the floor with them. An engine without
  /// the extension answers all nulls.
  Future<List<ArRay?>> rayAt(List<(double, double)> points);

  /// The tracked floor height and the tracked planes (fe_ar extension
  /// `planes`): walls for "Snap to wall" and the room corners "Snap corner"
  /// magnets to. [ArPlanes.empty] from an engine without the extension.
  Future<ArPlanes> planes();

  /// Turns the torch on or off (fe_ar extension `setTorch`). True when the
  /// engine applied it; see [ArCapabilities.torch].
  Future<bool> setTorch(bool on);

  /// Restarts the camera's autofocus sweep (fe_ar extension `refocus`;
  /// ARCore/ARKit have no focus-at-point). True when the engine did it.
  Future<bool> refocus();

  /// The room-scan overlay (fe_ar extension `setScanOverlay`): on iPhones
  /// and iPads with LiDAR the live scene mesh, tinted by surface type, painting
  /// itself in as the room is discovered; elsewhere the tracked planes as an
  /// animated grid. Native fades it in and out. [contrast] is Sunlight mode.
  /// True when the engine can draw it; false from an engine without it.
  Future<bool> setScanOverlay(bool on, {bool contrast = false});

  /// Two expanding rings where a board or corner was just confirmed (fe_ar
  /// extension `pulseAt`, iOS): [tone] `ok` (green: the depth check agreed),
  /// `warn` (amber: it didn't) or `info` (blue: nothing to check against).
  /// False when the engine has no rings.
  Future<bool> pulseAt(Vec3 posAr, {Vec3? normalAr, String tone = 'info'});

  /// Turns the engine's depth sensing on or off (fe_ar extension
  /// `setDepth`). Depth is costly; only setup (corner snaps, wall taps)
  /// needs it. True when applied.
  Future<bool> setDepth(bool on);

  /// Starts recording the running session to [path] (fe_ar extension; debug
  /// builds). False when the engine couldn't.
  Future<bool> startRecording(String path);

  /// Stops a recording; the file's path, or null when none was running.
  Future<String?> stopRecording();

  /// A JPEG of camera plus overlay; the file path, or null if unavailable.
  Future<String?> capture();

  Future<void> pause();
  Future<void> resume();
  Future<void> stop();

  /// Low-rate events, never per frame (§6.4).
  Stream<ArEvent> get events;
}

/// What this device can do (docs/ar-bim-overlay.md §6.7).
class ArCapabilities {
  const ArCapabilities({
    required this.supported,
    this.depth = false,
    this.lidar = false,
    this.recording = false,
    this.platform = 'unknown',
    this.reason,
    this.torch = false,
    this.mesh = false,
    this.scanOverlay = false,
  });

  const ArCapabilities.unsupported(String this.reason, {this.platform = 'unknown'})
      : supported = false,
        depth = false,
        lidar = false,
        recording = false,
        torch = false,
        mesh = false,
        scanOverlay = false;

  /// The plugin isn't in this build or this platform has no engine.
  static const engineNotInstalled = 'engine-not-installed';

  factory ArCapabilities.fromMap(Map<dynamic, dynamic> map) => ArCapabilities(
        supported: asBool(map['supported']) ?? false,
        depth: asBool(map['depth']) ?? false,
        lidar: asBool(map['lidar']) ?? false,
        recording: asBool(map['recording']) ?? false,
        platform: map['platform']?.toString() ?? 'unknown',
        reason: map['reason']?.toString(),
        torch: asBool(map['torch']) ?? false,
        mesh: asBool(map['mesh']) ?? false,
        scanOverlay: asBool(map['scanOverlay']) ?? false,
      );

  final bool supported;
  final bool depth;
  final bool lidar;
  final bool recording;

  /// The back camera has a torch the engine can switch ([ArEngine.setTorch]).
  /// fe_ar extension key `torch`; false from an older plugin.
  final bool torch;

  /// The LiDAR scene mesh runs here (fe_ar extension key `mesh`, iOS): the
  /// room-scan overlay draws real surfaces, corner snaps use them.
  final bool mesh;

  /// The engine draws the room-scan overlay ([ArEngine.setScanOverlay];
  /// extension key `scanOverlay`). False from an older plugin.
  final bool scanOverlay;

  /// `android | ios | demo | unknown`.
  final String platform;

  /// Why AR is unsupported (`engine-not-installed`, `arcore-missing`,
  /// `camera-denied`, …); null when supported.
  final String? reason;

  /// Capability tier: `A+` LiDAR, `A` depth, `B` tracking only, `C` no AR
  /// ("Show in AR" becomes "Show on floor plan"). Recorded as the alignment
  /// event's `deviceTier`.
  String get tier => !supported
      ? 'C'
      : lidar
          ? 'A+'
          : depth
              ? 'A'
              : 'B';

  Map<String, dynamic> toMap() => {
        'supported': supported,
        'depth': depth,
        'lidar': lidar,
        'recording': recording,
        'platform': platform,
        'reason': reason,
        'torch': torch,
        'mesh': mesh,
        'scanOverlay': scanOverlay,
      };
}

/// A measured surface point ([ArEngine.depthPointAt]).
class ArDepthPoint {
  const ArDepthPoint({
    required this.posAr,
    this.normalAr,
    this.confidence = 0,
    this.method = 'rawDepth',
  });

  final Vec3 posAr;

  /// Unit surface normal facing the camera, when the patch around the point
  /// was flat enough to give one.
  final Vec3? normalAr;

  /// 0–1: the share of confident depth pixels around the point, times their
  /// mean confidence (Raw Depth); 0.9 for a tracked plane.
  final double confidence;

  /// `rawDepth | plane | depth`.
  final String method;

  static ArDepthPoint? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final pos = Vec3.tryParse(raw['posAr']);
    if (pos == null) return null;
    return ArDepthPoint(
      posAr: pos,
      normalAr: Vec3.tryParse(raw['normalAr']),
      confidence: asDouble(raw['confidence']) ?? 0,
      method: raw['method']?.toString() ?? 'rawDepth',
    );
  }

  Map<String, dynamic> toMap() => {
        'posAr': posAr.toList(),
        'normalAr': normalAr?.toList(),
        'confidence': confidence,
        'method': method,
      };
}

/// A world ray through a view point ([ArEngine.rayAt]): where a finger on
/// the screen points into the room. "Place by hand" intersects it with the
/// floor plane in Dart (`manual_place_math.dart`), so the model follows the
/// finger without a native hit-test per frame.
class ArRay {
  const ArRay({required this.originAr, required this.dirAr});

  /// On the near plane, AR world.
  final Vec3 originAr;

  /// Unit direction, AR world.
  final Vec3 dirAr;

  static ArRay? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final o = Vec3.tryParse(raw['originAr']);
    final d = Vec3.tryParse(raw['dirAr']);
    if (o == null || d == null || d.length < 1e-9) return null;
    return ArRay(originAr: o, dirAr: d.normalized);
  }

  Map<String, dynamic> toMap() => {'originAr': originAr.toList(), 'dirAr': dirAr.toList()};
}

/// One tracked plane ([ArEngine.planes]): a wall the phone has measured, or
/// the floor. "Place by hand" snaps the model's walls and corners to them.
class ArPlane {
  const ArPlane({
    required this.id,
    required this.kind,
    required this.centerAr,
    required this.normalAr,
    this.segment,
    this.widthM = 0,
    this.heightM = 0,
  });

  final String id;

  /// `wall | floor | ceiling | other`.
  final String kind;
  final Vec3 centerAr;

  /// Unit normal; for a wall it is horizontal and faces the camera (into
  /// the room the user stands in).
  final Vec3 normalAr;

  /// Walls: the plane's horizontal extent on the floor plane, two (x, z)
  /// ends. Null for floors (and an old engine).
  final (Vec2, Vec2)? segment;
  final double widthM;
  final double heightM;

  bool get isWall => kind == 'wall';

  static ArPlane? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final c = Vec3.tryParse(raw['centerAr']);
    final n = Vec3.tryParse(raw['normalAr']);
    if (c == null || n == null || n.length < 1e-6) return null;
    (Vec2, Vec2)? seg;
    final s = raw['segment'];
    if (s is List && s.length >= 2) {
      final a = Vec2.tryParse(s[0]);
      final b = Vec2.tryParse(s[1]);
      if (a != null && b != null) seg = (a, b);
    }
    return ArPlane(
      id: raw['id']?.toString() ?? '',
      kind: raw['kind']?.toString() ?? 'other',
      centerAr: c,
      normalAr: n.normalized,
      segment: seg,
      widthM: asDouble(raw['widthM']) ?? 0,
      heightM: asDouble(raw['heightM']) ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'kind': kind,
        'centerAr': centerAr.toList(),
        'normalAr': normalAr.toList(),
        if (segment != null) 'segment': [segment!.$1.toList(), segment!.$2.toList()],
        'widthM': widthM,
        'heightM': heightM,
      };
}

/// What [ArEngine.planes] answers: the tracked floor height (the same plane
/// the `floor` event reports) and the tracked planes.
class ArPlanes {
  const ArPlanes({this.floorY, this.planes = const []});

  static const empty = ArPlanes();

  final double? floorY;
  final List<ArPlane> planes;

  List<ArPlane> get walls => [for (final p in planes) if (p.isWall) p];

  static ArPlanes fromMap(dynamic raw) {
    if (raw is! Map) return empty;
    final list = raw['planes'];
    return ArPlanes(
      floorY: asDouble(raw['floorY']),
      planes: [
        if (list is List)
          for (final p in list) ?ArPlane.fromMap(p),
      ],
    );
  }
}

class TileRef {
  const TileRef({required this.hash, required this.path});

  final String hash;
  final String path;

  Map<String, dynamic> toMap() => {'hash': hash, 'path': path};
}

/// The answer to `loadTiles` (CHANNEL.md): the hashes now resident (or
/// already loading) and those that failed, with the native reason.
class TileLoadResult {
  const TileLoadResult({required this.loaded, this.failed = const {}});

  /// Every asked tile resident: a plugin that answers without a result map.
  TileLoadResult.all(List<TileRef> tiles)
      : loaded = [for (final t in tiles) t.hash],
        failed = const {};

  /// Reads the native `{loaded: [hash], failed: [{hash, reason}]}`. Anything
  /// else (an older plugin answering `null`) counts every tile as loaded,
  /// which is what the session assumed before the answer was read.
  factory TileLoadResult.fromWire(Object? raw, List<TileRef> asked) {
    if (raw is! Map) return TileLoadResult.all(asked);
    final loaded = raw['loaded'];
    final failed = <String, String>{};
    final rawFailed = raw['failed'];
    if (rawFailed is List) {
      for (final f in rawFailed) {
        if (f is Map && f['hash'] is String) failed[f['hash'] as String] = '${f['reason'] ?? 'failed'}';
      }
    }
    return TileLoadResult(
      loaded: loaded is List ? [for (final h in loaded) if (h is String) h] : [for (final t in asked) if (!failed.containsKey(t.hash)) t.hash],
      failed: failed,
    );
  }

  final List<String> loaded;

  /// hash → reason.
  final Map<String, String> failed;
}

/// Layer toggles and the section plane (docs/ar-setup-and-gamma-parity.md
/// §2.9 Layers panel).
class LayerState {
  const LayerState({
    this.mep = true,
    this.structure = true,
    this.architecture = true,
    this.opacity = 1,
    this.sectionY,
    this.contrast = false,
  });

  final bool mep;
  final bool structure;
  final bool architecture;

  /// Model opacity 0–1 over the camera.
  final double opacity;

  /// Tile-frame height of a horizontal section plane; null for none.
  final double? sectionY;

  /// Sunlight mode (extra `contrast`): opaque MEP, white edges.
  final bool contrast;

  LayerState copyWith({
    bool? mep,
    bool? structure,
    bool? architecture,
    double? opacity,
    double? sectionY,
    bool clearSection = false,
    bool? contrast,
  }) =>
      LayerState(
        mep: mep ?? this.mep,
        structure: structure ?? this.structure,
        architecture: architecture ?? this.architecture,
        opacity: math.min(1.0, math.max(0.0, opacity ?? this.opacity)),
        sectionY: clearSection ? null : (sectionY ?? this.sectionY),
        contrast: contrast ?? this.contrast,
      );

  Map<String, dynamic> toMap() => {
        'mep': mep,
        'structure': structure,
        'architecture': architecture,
        'opacity': opacity,
        'sectionY': sectionY,
        if (contrast) 'contrast': true,
      };

  @override
  bool operator ==(Object other) =>
      other is LayerState &&
      other.mep == mep &&
      other.structure == structure &&
      other.architecture == architecture &&
      other.opacity == opacity &&
      other.sectionY == sectionY &&
      other.contrast == contrast;

  @override
  int get hashCode => Object.hash(mep, structure, architecture, opacity, sectionY, contrast);
}

/// One structural grid line on the floor plane, `(x, z)` in the tile frame.
class GridLineRef {
  const GridLineRef({required this.name, required this.p0, required this.p1});

  final String name;
  final Vec2 p0;
  final Vec2 p1;

  Map<String, dynamic> toMap() => {
        'name': name,
        'p0': p0.toList(),
        'p1': p1.toList(),
      };
}

/// A pin drawn in the model: a snag, a finding, a clash, or the ghost board
/// of "leave a board".
class ArPin {
  const ArPin({
    required this.id,
    required this.posTile,
    this.label = '',
    this.kind = 'snag',
    this.colorRgb,
    this.normalTile,
  });

  final String id;
  final Vec3 posTile;
  final String label;

  /// `snag | finding | clash | ghostBoard | board | measure`.
  final String kind;

  /// 0xRRGGBB, or null for the kind's default colour.
  final int? colorRgb;

  /// For a board-shaped pin (the ghost board): which way it faces.
  final Vec3? normalTile;

  Map<String, dynamic> toMap() => {
        'id': id,
        'posTile': posTile.toList(),
        'label': label,
        'kind': kind,
        'colorRgb': colorRgb,
        'normalTile': normalTile?.toList(),
      };
}

class PickResult {
  const PickResult({
    required this.featureId,
    required this.hitPointTile,
    required this.distanceM,
    this.tileHash,
    this.buildId,
  });

  /// Dense per build (manifest features); resolve through `ar_features`.
  final int featureId;
  final Vec3 hitPointTile;
  final double distanceM;
  final String? tileHash;
  final String? buildId;

  static PickResult? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final id = asInt(raw['featureId']);
    final hit = Vec3.tryParse(raw['hitPointTile']);
    if (id == null || hit == null) return null;
    return PickResult(
      featureId: id,
      hitPointTile: hit,
      distanceM: asDouble(raw['distanceM']) ?? 0,
      tileHash: raw['tileHash']?.toString(),
      buildId: raw['buildId']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'featureId': featureId,
        'hitPointTile': hitPointTile.toList(),
        'distanceM': distanceM,
        'tileHash': tileHash,
        'buildId': buildId,
      };
}

/// Tracking states as the engine reports them (lower-case on both
/// platforms; ARCore's TRACKING/PAUSED/STOPPED and ARKit's
/// normal/limited/notAvailable are mapped natively).
abstract final class ArTracking {
  static const initializing = 'initializing';
  static const tracking = 'tracking';
  static const limited = 'limited';
  static const paused = 'paused';
  static const stopped = 'stopped';
  static const notAvailable = 'notAvailable';
}

/// Native → Dart events on `fusioneco/ar/events`. Each is a map whose
/// `type` is one of `tracking | marker | corner | anchor | pose |
/// targetScreen | error`, with fields named like these classes.
sealed class ArEvent {
  const ArEvent();

  String get type;

  Map<String, dynamic> toMap();

  /// Null for an unknown `type` (a newer plugin's event this app doesn't
  /// know yet: ignored, never a crash). A known type with missing required
  /// fields becomes an [ArErrorEvent] with code `bad-event`, so a plugin bug
  /// is visible rather than silently dropped.
  static ArEvent? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final type = raw['type']?.toString();
    ArEvent bad(String what) => ArErrorEvent(code: 'bad-event', detail: '$type: $what');
    switch (type) {
      case 'tracking':
        return TrackingEvent(
          state: raw['state']?.toString() ?? ArTracking.limited,
          reason: raw['reason']?.toString(),
        );
      case 'marker':
        final centre = Vec3.tryParse(raw['centreAr']);
        final normal = Vec3.tryParse(raw['normalAr']);
        final payload = raw['rawPayload']?.toString();
        if (centre == null || normal == null || payload == null) return bad('centreAr/normalAr/rawPayload');
        return MarkerSeenEvent(
          rawPayload: payload,
          anchorId: raw['anchorId']?.toString() ?? '',
          centreAr: centre,
          normalAr: normal,
          method: raw['method']?.toString() ?? 'plane',
          spreadMm: asDouble(raw['spreadMm']) ?? 0,
          distanceM: asDouble(raw['distanceM']) ?? 0,
          viewAngleDeg: asDouble(raw['viewAngleDeg']) ?? 0,
          qrEdgeMm: asDouble(raw['qrEdgeMm']),
          surfaceResidualMm: asDouble(raw['surfaceResidualMm']),
        );
      case 'corner':
        final corner = CornerSeenEvent.tryParse(raw);
        return corner ?? bad('posAr/faceAAr/faceBAr');
      case 'anchor':
        final pos = Vec3.tryParse(raw['posAr']);
        final id = raw['anchorId']?.toString();
        if (pos == null || id == null) return bad('anchorId/posAr');
        return AnchorUpdatedEvent(anchorId: id, posAr: pos);
      case 'thermal':
        return ThermalEvent(level: raw['level']?.toString() ?? 'none', status: asInt(raw['status']) ?? 0);
      case 'scan':
        return ScanProgressEvent(
          source: raw['source']?.toString() ?? 'planes',
          walls: asInt(raw['walls']) ?? 0,
          floors: asInt(raw['floors']) ?? 0,
          floorM2: asDouble(raw['floorM2']) ?? 0,
          wallM2: asDouble(raw['wallM2']) ?? 0,
          ceilingM2: asDouble(raw['ceilingM2']) ?? 0,
          otherM2: asDouble(raw['otherM2']) ?? 0,
        );
      case 'floor':
        final y = asDouble(raw['yAr']);
        if (y == null) return bad('yAr');
        return FloorPlaneEvent(yAr: y, areaM2: asDouble(raw['areaM2']) ?? 0);
      case 'pose':
        final m = Mat4.tryParse(raw['arFromCamera']);
        if (m == null) return bad('arFromCamera');
        return CameraPoseEvent(arFromCamera: m);
      case 'targetScreen':
        return TargetScreenEvent(
          x: asDouble(raw['x']) ?? 0,
          y: asDouble(raw['y']) ?? 0,
          onScreen: asBool(raw['onScreen']) ?? false,
        );
      case 'error':
        return ArErrorEvent(
          code: raw['code']?.toString() ?? 'unknown',
          detail: raw['detail']?.toString() ?? '',
        );
      default:
        return null;
    }
  }
}

final class TrackingEvent extends ArEvent {
  const TrackingEvent({required this.state, this.reason});

  /// [ArTracking] values.
  final String state;

  /// `excessiveMotion | insufficientFeatures | insufficientLight |
  /// relocalizing | initializing`, or null.
  final String? reason;

  bool get isTracking => state == ArTracking.tracking;

  @override
  String get type => 'tracking';

  @override
  Map<String, dynamic> toMap() => {'type': type, 'state': state, 'reason': reason};
}

/// A board the engine accepted (§4.2: tracking, 0.5–2 m, within 35° of the
/// normal, stable decode, about a second of frames, spread ≤ 15 mm). Parse
/// [rawPayload] with `MarkerCode.fromScan`.
final class MarkerSeenEvent extends ArEvent {
  const MarkerSeenEvent({
    required this.rawPayload,
    required this.anchorId,
    required this.centreAr,
    required this.normalAr,
    required this.method,
    required this.spreadMm,
    required this.distanceM,
    required this.viewAngleDeg,
    this.qrEdgeMm,
    this.surfaceResidualMm,
  });

  final String rawPayload;
  final String anchorId;

  /// Registration point (QR centre) in the AR world.
  final Vec3 centreAr;
  final Vec3 normalAr;

  /// `lidar | plane | depth | pnp`.
  final String method;
  final double spreadMm;
  final double distanceM;
  final double viewAngleDeg;

  /// Measured QR edge length from depth or LiDAR, for the print-scale check;
  /// null without a depth sensor.
  final double? qrEdgeMm;

  /// The LiDAR check (fe_ar extension, iOS): how far the wall the depth
  /// sensor sees is behind (+) or in front of (−) the locked centre, in mm.
  /// Null without LiDAR depth.
  final double? surfaceResidualMm;

  @override
  String get type => 'marker';

  @override
  Map<String, dynamic> toMap() => {
        'type': type,
        'rawPayload': rawPayload,
        'anchorId': anchorId,
        'centreAr': centreAr.toList(),
        'normalAr': normalAr.toList(),
        'method': method,
        'spreadMm': spreadMm,
        'distanceM': distanceM,
        'viewAngleDeg': viewAngleDeg,
        'qrEdgeMm': qrEdgeMm,
        'surfaceResidualMm': surfaceResidualMm,
      };
}

/// A corner snapped under the pin: where the corner line meets the floor,
/// and the two faces' horizontal normals `(x, z)` oriented toward the camera.
final class CornerSeenEvent extends ArEvent {
  const CornerSeenEvent({
    required this.posAr,
    required this.faceAAr,
    required this.faceBAr,
    required this.angleDeg,
    required this.kind,
    required this.method,
    this.surfaceResidualMm,
  });

  final Vec3 posAr;
  final Vec2 faceAAr;
  final Vec2 faceBAr;
  final double angleDeg;

  /// `inside | outside | column`.
  final String kind;

  /// `lidar | planes | floorTap` from the engine; `depthTaps` when Dart
  /// fitted it from wall taps (`wall_fit.dart`).
  final String method;

  /// The LiDAR check of the corner line against scene depth (fe_ar
  /// extension, iOS), mm; null without LiDAR depth.
  final double? surfaceResidualMm;

  static CornerSeenEvent? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final pos = Vec3.tryParse(raw['posAr']);
    final a = Vec2.tryParse(raw['faceAAr']);
    final b = Vec2.tryParse(raw['faceBAr']);
    if (pos == null || a == null || b == null) return null;
    return CornerSeenEvent(
      posAr: pos,
      faceAAr: a,
      faceBAr: b,
      angleDeg: asDouble(raw['angleDeg']) ?? 90,
      kind: raw['kind']?.toString() ?? 'inside',
      method: raw['method']?.toString() ?? 'planes',
      surfaceResidualMm: asDouble(raw['surfaceResidualMm']),
    );
  }

  @override
  String get type => 'corner';

  @override
  Map<String, dynamic> toMap() => {
        'type': type,
        'posAr': posAr.toList(),
        'faceAAr': faceAAr.toList(),
        'faceBAr': faceBAr.toList(),
        'angleDeg': angleDeg,
        'kind': kind,
        'method': method,
        'surfaceResidualMm': ?surfaceResidualMm,
      };
}

/// The tracker refined a native anchor (at most 2 Hz). Refit with the
/// observation's new position (`ArObservation.withAr`).
final class AnchorUpdatedEvent extends ArEvent {
  const AnchorUpdatedEvent({required this.anchorId, required this.posAr});

  final String anchorId;
  final Vec3 posAr;

  @override
  String get type => 'anchor';

  @override
  Map<String, dynamic> toMap() => {
        'type': type,
        'anchorId': anchorId,
        'posAr': posAr.toList(),
      };
}

/// The phone's thermal status changed (fe_ar extension, Android 10+):
/// `none | light | moderate | severe | critical | emergency | shutdown`.
final class ThermalEvent extends ArEvent {
  const ThermalEvent({required this.level, this.status = 0});

  final String level;
  final int status;

  /// Hot enough that the OS is about to throttle: pause AR.
  bool get isHot => status >= 3;

  @override
  String get type => 'thermal';

  @override
  Map<String, dynamic> toMap() => {'type': type, 'level': level, 'status': status};
}

/// The tracked floor (fe_ar extension): the lowest upward plane a standing
/// phone's height below the camera. The fit takes the model's height from it
/// instead of from board centres, so a board hung 5 cm off no longer lifts
/// the whole model. At most 1 Hz, and only when it moves by 1 cm.
final class FloorPlaneEvent extends ArEvent {
  const FloorPlaneEvent({required this.yAr, this.areaM2 = 0});

  final double yAr;
  final double areaM2;

  @override
  String get type => 'floor';

  @override
  Map<String, dynamic> toMap() => {'type': type, 'yAr': yAr, 'areaM2': areaM2};
}

/// Camera pose, 5 Hz while subscribed. Drives tile residency, the target
/// arrow, the nudge axis and "distance walked".
final class CameraPoseEvent extends ArEvent {
  const CameraPoseEvent({required this.arFromCamera});

  final Mat4 arFromCamera;

  Vec3 get positionAr => arFromCamera.translation;

  /// The camera looks down its own −Z (ARKit and ARCore both).
  Vec3 get forwardAr => arFromCamera.transformDir(const Vec3(0, 0, -1));

  @override
  String get type => 'pose';

  @override
  Map<String, dynamic> toMap() => {'type': type, 'arFromCamera': arFromCamera.toList()};
}

/// Where the target is on screen (10 Hz while a target is set), for the
/// off-screen arrow.
final class TargetScreenEvent extends ArEvent {
  const TargetScreenEvent({required this.x, required this.y, required this.onScreen});

  final double x;
  final double y;
  final bool onScreen;

  @override
  String get type => 'targetScreen';

  @override
  Map<String, dynamic> toMap() => {'type': type, 'x': x, 'y': y, 'onScreen': onScreen};
}

/// What the room scan has found (fe_ar extension, at most 1 Hz while the
/// scan overlay is on): tracked floors and walls, and the measured area by
/// surface type. `source` is `mesh` (LiDAR) or `planes`.
/// `lib/core/ar/scan_overlay.dart` turns it into the setup's scan progress.
final class ScanProgressEvent extends ArEvent {
  const ScanProgressEvent({
    this.source = 'planes',
    this.walls = 0,
    this.floors = 0,
    this.floorM2 = 0,
    this.wallM2 = 0,
    this.ceilingM2 = 0,
    this.otherM2 = 0,
  });

  final String source;
  final int walls;
  final int floors;
  final double floorM2;
  final double wallM2;
  final double ceilingM2;
  final double otherM2;

  @override
  String get type => 'scan';

  @override
  Map<String, dynamic> toMap() => {
        'type': type,
        'source': source,
        'walls': walls,
        'floors': floors,
        'floorM2': floorM2,
        'wallM2': wallM2,
        'ceilingM2': ceilingM2,
        'otherM2': otherM2,
      };
}

final class ArErrorEvent extends ArEvent {
  const ArErrorEvent({required this.code, this.detail = ''});

  final String code;
  final String detail;

  @override
  String get type => 'error';

  @override
  Map<String, dynamic> toMap() => {'type': type, 'code': code, 'detail': detail};
}
