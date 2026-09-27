import '../core/ar/vec.dart';
import '../core/network/envelope.dart';

/// `projectTile` — the fe_ar extension (packages/fe_ar/CHANNEL.md), typed on
/// `ArEngine` since 2026-09-27. Called dynamically and read tolerantly so a
/// test double without it (or a slightly different return shape) no-ops
/// instead of throwing: the labels simply don't draw.
class ArEngineExtras {
  ArEngineExtras(this.engine);

  /// The session's engine (`ArSessionController.engine`), or null.
  final Object? engine;

  bool _noProject = false;

  /// False once the engine has shown it lacks `projectTile`.
  bool get canProject => engine != null && !_noProject;

  /// Tile-frame points → view logical pixels (null per point when the
  /// engine can't place it). Null overall when unsupported or it failed.
  Future<List<ArScreenPoint?>?> projectTile(List<Vec3> pointsTile) async {
    final e = engine;
    if (e == null || _noProject || pointsTile.isEmpty) return null;
    try {
      final raw = await (e as dynamic).projectTile(pointsTile);
      return ArScreenPoint.parseList(raw, pointsTile.length);
    } on NoSuchMethodError {
      _noProject = true;
      return null;
    } on TypeError {
      // A different argument shape: try the wire's `[[x,y,z]]` once.
      try {
        final raw = await (e as dynamic).projectTile([for (final p in pointsTile) p.toList()]);
        return ArScreenPoint.parseList(raw, pointsTile.length);
      } catch (_) {
        _noProject = true;
        return null;
      }
    } catch (_) {
      return null;
    }
  }

}

/// One projected point: view logical pixels from the top-left, and whether
/// it is in front of the camera and inside the view (CHANNEL.md
/// `projectTile`: `[x, y, onScreen] | null`).
class ArScreenPoint {
  const ArScreenPoint(this.x, this.y, {this.onScreen = true});

  final double x;
  final double y;
  final bool onScreen;

  /// Tolerant: a record `(x, y, onScreen)`, a list `[x, y, onScreen?]`, a
  /// map `{x, y, onScreen}`, or null.
  static ArScreenPoint? parse(dynamic raw) {
    if (raw == null) return null;
    if (raw is ArScreenPoint) return raw;
    if (raw is (num, num, bool)) return ArScreenPoint(raw.$1.toDouble(), raw.$2.toDouble(), onScreen: raw.$3);
    if (raw is (num, num)) return ArScreenPoint(raw.$1.toDouble(), raw.$2.toDouble());
    if (raw is List && raw.length >= 2) {
      final x = asDouble(raw[0]);
      final y = asDouble(raw[1]);
      if (x == null || y == null) return null;
      return ArScreenPoint(x, y, onScreen: raw.length < 3 || (asBool(raw[2]) ?? true));
    }
    if (raw is Map) {
      final x = asDouble(raw['x']);
      final y = asDouble(raw['y']);
      if (x == null || y == null) return null;
      return ArScreenPoint(x, y, onScreen: asBool(raw['onScreen']) ?? true);
    }
    return null;
  }

  /// [expected] entries, padded with nulls; null when [raw] isn't a list.
  static List<ArScreenPoint?>? parseList(dynamic raw, int expected) {
    if (raw is! List) return null;
    return [for (var i = 0; i < expected; i++) i < raw.length ? parse(raw[i]) : null];
  }
}
