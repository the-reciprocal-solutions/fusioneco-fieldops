import 'dart:convert';
import 'dart:math' as math;

import '../ar/vec.dart';

/// The wire between Dart and the model viewer's 3D engine
/// (docs/bim-viewer.md §4). Pure Dart — no Flutter — so every shape is
/// unit-tested on any SDK.
///
/// Today the engine is `assets/bim_viewer/viewer.js` (three.js in a WebView):
/// a command becomes `window.feViewer.run({cmd, args})`, an event arrives on
/// the `FeViewer` JavaScript channel as one JSON object. A native engine
/// (Filament in `packages/fe_ar`, once it has a non-AR camera) would carry
/// the same maps over a MethodChannel, so the screens never change.
///
/// Frames: all positions are the tile frame of contract C2 (building-local,
/// metres, Y up). The plan is the tile frame's XZ, x right and z down.

/// Orbit around a target (overview, the default) or walk at eye height.
enum BimCameraMode {
  orbit('orbit'),
  walk('walk');

  const BimCameraMode(this.wire);
  final String wire;

  static BimCameraMode parse(String? v) => v == 'walk' ? walk : orbit;
}

/// What a tap in 3D does: select an element, or place a measuring point.
enum BimTool {
  select('none'),
  measure('measure');

  const BimTool(this.wire);
  final String wire;
}

/// What the 3D view draws. `architecture` is the AR edge layer (outlines);
/// `architectureSolid` the viewer-only shaded walls; `massing` the walls
/// extruded from the plan when a floor has no solid tiles (older builds,
/// Demo). `cut` clips walls and slabs 2.2 m above the floor in orbit so
/// rooms read from above; `xray` makes walls and slabs see-through.
class BimLayerState {
  const BimLayerState({
    this.mep = true,
    this.structure = true,
    this.architecture = true,
    this.architectureSolid = true,
    this.massing = true,
    this.xray = false,
    this.cut = true,
  });

  final bool mep;
  final bool structure;
  final bool architecture;
  final bool architectureSolid;
  final bool massing;
  final bool xray;
  final bool cut;

  BimLayerState copyWith({
    bool? mep,
    bool? structure,
    bool? architecture,
    bool? architectureSolid,
    bool? massing,
    bool? xray,
    bool? cut,
  }) =>
      BimLayerState(
        mep: mep ?? this.mep,
        structure: structure ?? this.structure,
        architecture: architecture ?? this.architecture,
        architectureSolid: architectureSolid ?? this.architectureSolid,
        massing: massing ?? this.massing,
        xray: xray ?? this.xray,
        cut: cut ?? this.cut,
      );

  /// The keys are viewer.js' layer names (the server's tile layers).
  Map<String, Object?> toArgs() => {
        'mep': mep,
        'structure': structure,
        'architecture': architecture,
        'architecture_solid': architectureSolid,
        'massing': massing,
        'xray': xray,
        'cut': cut,
      };

  @override
  bool operator ==(Object other) =>
      other is BimLayerState &&
      other.mep == mep &&
      other.structure == structure &&
      other.architecture == architecture &&
      other.architectureSolid == architectureSolid &&
      other.massing == massing &&
      other.xray == xray &&
      other.cut == cut;

  @override
  int get hashCode => Object.hash(mep, structure, architecture, architectureSolid, massing, xray, cut);
}

/// A tile the engine should hold: its content hash (the file name it is
/// served under), its layer and its build (for feature lookups).
class BimTileSpec {
  const BimTileSpec({required this.hash, required this.layer, required this.buildId});
  final String hash;
  final String layer;
  final String buildId;

  Map<String, Object?> toJson() => {'hash': hash, 'layer': layer, 'buildId': buildId};
}

/// One wall of the plan-massing fallback: a polyline and a thickness (m).
class BimMassingWall {
  const BimMassingWall(this.points, {this.thicknessM = 0.2});
  final List<Vec2> points;
  final double thicknessM;

  Map<String, Object?> toJson() => {
        'pts': [for (final p in points) [_r(p.x), _r(p.y)]],
        't': thicknessM,
      };
}

double _r(double v) => (v * 1000).roundToDouble() / 1000;

/// A command for the engine. Build one with the named constructors; the
/// engine sends [toJson] (`{cmd, args}`).
class BimViewCommand {
  const BimViewCommand._(this.name, [this.args = const {}]);

  final String name;
  final Map<String, Object?> args;

  factory BimViewCommand.setTheme({required bool dark}) => BimViewCommand._('setTheme', {'dark': dark});

  /// The floor: its datum (tile-frame y of the finished floor), plan bounds
  /// `[minX, minZ, maxX, maxZ]` for framing, eye height for walking, and
  /// the orbit cut height above the datum.
  factory BimViewCommand.setFloor({
    required double datumY,
    required List<double> bounds,
    double eyeHeightM = 1.6,
    double cutHeightM = 2.2,
  }) =>
      BimViewCommand._('setFloor', {
        'datumY': datumY,
        'bounds': bounds,
        'eyeHeightM': eyeHeightM,
        'cutHeightM': cutHeightM,
      });

  /// Replace the resident tile set: tiles not listed are unloaded, new
  /// ones are fetched from `<base><hash>.glb`.
  factory BimViewCommand.setTiles({required String base, required List<BimTileSpec> tiles}) =>
      BimViewCommand._('setTiles', {
        'base': base,
        'tiles': [for (final t in tiles) t.toJson()],
      });

  factory BimViewCommand.setPlan({
    required double datumY,
    required List<BimMassingWall> walls,
    List<List<Vec2>> columns = const [],
    List<double>? bounds,
    double heightM = 3,
  }) =>
      BimViewCommand._('setPlan', {
        'datumY': datumY,
        'heightM': heightM,
        'walls': [for (final w in walls) w.toJson()],
        'columns': [
          for (final c in columns) [for (final p in c) [_r(p.x), _r(p.y)]],
        ],
        'bounds': bounds,
      });

  factory BimViewCommand.setLayers(BimLayerState layers) => BimViewCommand._('setLayers', layers.toArgs());

  factory BimViewCommand.setMode(BimCameraMode mode) => BimViewCommand._('setMode', {'mode': mode.wire});

  /// Move the camera to a plan point (a tap on the 2D plan). Walk keeps its
  /// height; orbit re-targets. An optional plan heading turns the walker.
  factory BimViewCommand.flyTo({required double x, required double z, Vec2? heading}) =>
      BimViewCommand._('flyTo', {
        'x': x,
        'z': z,
        if (heading != null) 'headingX': heading.x,
        if (heading != null) 'headingZ': heading.y,
      });

  /// Highlight a feature and (with [frame]) move the camera to it. The box
  /// is used when the feature's tile isn't resident (Demo, not downloaded).
  factory BimViewCommand.select({
    required int featureId,
    String? buildId,
    bool frame = true,
    Vec3? bboxMin,
    Vec3? bboxMax,
  }) =>
      BimViewCommand._('select', {
        'featureId': featureId,
        'buildId': buildId,
        'frame': frame,
        if (bboxMin != null) 'bboxMin': bboxMin.toList(),
        if (bboxMax != null) 'bboxMax': bboxMax.toList(),
      });

  factory BimViewCommand.clearSelection() => const BimViewCommand._('clearSelection');

  /// What a 3D tap does. Leaving measure clears the measurement.
  factory BimViewCommand.setTool(BimTool tool) => BimViewCommand._('setTool', {'tool': tool.wire});

  /// Orbit section cut height above the floor datum (m).
  factory BimViewCommand.setCut(double heightM) => BimViewCommand._('setCut', {'heightM': heightM});

  factory BimViewCommand.clearMeasure() => const BimViewCommand._('clearMeasure');

  factory BimViewCommand.resetView() => const BimViewCommand._('resetView');

  Map<String, Object?> toJson() => {'cmd': name, 'args': args};

  /// The JavaScript that runs this command in viewer.js. JSON is a valid JS
  /// expression, and `jsonEncode` escapes every quote, so nothing a model
  /// name contains can break out of the call.
  String toJavaScript() => 'window.feViewer.run(${jsonEncode(toJson())});';

  @override
  String toString() => 'BimViewCommand($name)';
}

/// Something the engine reports. Unknown types parse to null (ignored), so
/// a newer viewer.js never breaks an older app.
sealed class BimViewEvent {
  const BimViewEvent();

  static BimViewEvent? parse(Object? raw) {
    Map<String, dynamic>? m;
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) m = Map<String, dynamic>.from(decoded);
      } catch (_) {
        return null;
      }
    } else if (raw is Map) {
      m = Map<String, dynamic>.from(raw);
    }
    if (m == null) return null;
    return switch (m['type']) {
      'ready' => BimReady(version: _int(m['version']) ?? 0, webgl2: m['webgl2'] == true),
      'tiles' => BimTilesProgress(
          loaded: _int(m['loaded']) ?? 0,
          failed: _int(m['failed']) ?? 0,
          total: _int(m['total']) ?? 0,
          resident: _int(m['resident']) ?? 0,
          triangles: _int(m['triangles']) ?? 0,
          done: m['done'] == true,
        ),
      'pose' => _pose(m),
      'pick' => BimPick(
          featureId: _int(m['featureId']),
          buildId: m['buildId'] is String ? m['buildId'] as String : null,
          layer: m['layer'] is String ? m['layer'] as String : null,
          point: Vec3.tryParse(m['point']),
          none: m['none'] == true,
        ),
      'measure' => BimMeasure(
          points: [
            if (m['points'] is List)
              for (final p in m['points'] as List)
                if (Vec3.tryParse(p) case final v?) v,
          ],
          distanceM: _double(m['distanceM']),
          horizontalM: _double(m['horizontalM']),
          verticalM: _double(m['verticalM']),
        ),
      'error' => BimViewerError(
          code: m['code']?.toString() ?? 'ERROR',
          message: m['message']?.toString(),
        ),
      _ => null,
    };
  }

  static BimPose? _pose(Map<String, dynamic> m) {
    final pos = Vec3.tryParse(m['pos']);
    final dir = Vec3.tryParse(m['dir']);
    if (pos == null || dir == null) return null;
    return BimPose(
      position: pos,
      direction: dir,
      mode: BimCameraMode.parse(m['mode']?.toString()),
      fovDeg: _double(m['fovDeg']) ?? 60,
      target: Vec3.tryParse(m['target']),
    );
  }

  static int? _int(Object? v) => v is int ? v : (v is num && v == v.roundToDouble() ? v.toInt() : null);
  static double? _double(Object? v) => v is num ? v.toDouble() : null;
}

/// The page is up (WebGL context, meshopt decoder) and drained its queue.
class BimReady extends BimViewEvent {
  const BimReady({required this.version, required this.webgl2});
  final int version;
  final bool webgl2;
}

class BimTilesProgress extends BimViewEvent {
  const BimTilesProgress({
    required this.loaded,
    required this.failed,
    required this.total,
    required this.resident,
    required this.triangles,
    required this.done,
  });
  final int loaded;
  final int failed;
  final int total;
  final int resident;
  final int triangles;
  final bool done;
}

/// Where the 3D camera is (≤ 10 Hz, only when it moved): drives the split
/// view's position dot and view cone.
class BimPose extends BimViewEvent {
  const BimPose({
    required this.position,
    required this.direction,
    required this.mode,
    this.fovDeg = 60,
    this.target,
  });

  final Vec3 position;
  final Vec3 direction;
  final BimCameraMode mode;
  final double fovDeg;

  /// Orbit only: the point orbited (on the floor).
  final Vec3? target;

  /// Unit plan heading (x, z); null when looking straight down.
  Vec2? get planHeading {
    final l = math.sqrt(direction.x * direction.x + direction.z * direction.z);
    if (l < 1e-6) return null;
    return Vec2(direction.x / l, direction.z / l);
  }

  /// What the plan dot marks: the walker, or in orbit the orbited point
  /// (the camera itself hovers off the floor, often outside the plan).
  Vec2 get planPoint => mode == BimCameraMode.orbit && target != null ? target!.xz : position.xz;
}

/// A tap in 3D. [featureId] null: nothing with a feature was hit (the
/// floor, massing, or empty space — [none]).
class BimPick extends BimViewEvent {
  const BimPick({this.featureId, this.buildId, this.layer, this.point, this.none = false});
  final int? featureId;
  final String? buildId;
  final String? layer;
  final Vec3? point;
  final bool none;
}

/// The measure tool's state: 0, 1 or 2 points; distances once there are 2.
class BimMeasure extends BimViewEvent {
  const BimMeasure({this.points = const [], this.distanceM, this.horizontalM, this.verticalM});
  final List<Vec3> points;
  final double? distanceM;

  /// On the plan (clearance along the floor).
  final double? horizontalM;

  /// Height difference (headroom, drop to a valve).
  final double? verticalM;

  bool get complete => distanceM != null;
}

/// `NO_WEBGL`, `NO_WASM`, `CONTEXT_LOST`, `SCRIPT`, `COMMAND_FAILED`,
/// `UNKNOWN_COMMAND`, or `LOAD_FAILED` (Dart side: the page never came up).
class BimViewerError extends BimViewEvent {
  const BimViewerError({required this.code, this.message});
  final String code;
  final String? message;

  /// The page can't draw at all; show the 2D plan only.
  bool get fatal => code == 'NO_WEBGL' || code == 'NO_WASM' || code == 'LOAD_FAILED' || code == 'CONTEXT_LOST';
}
