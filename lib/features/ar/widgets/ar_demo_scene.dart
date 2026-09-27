import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../state/ar_view_models.dart';
import '../../../theme/fe_ar_colors.dart';
import '../../../theme/fe_colors.dart';

/// What the Demo scene should show on top of the "room".
class ArDemoSceneState {
  const ArDemoSceneState({
    this.placed = false,
    this.locked = false,
    this.showBoard = true,
    this.boardLabel = 'L03-M07',
    this.showGrid = false,
    this.showGhost = false,
    this.showModel = true,
    this.targetGlobalId,
    this.selected = const {},
    this.statusColors = const {},
    this.snagGlobalIds = const {},
    this.hidden = const {},
    this.opacity = 0.8,
    this.nudgePx = 0,
  });

  final bool placed;
  final bool locked;
  final bool showBoard;
  final String boardLabel;
  final bool showGrid;
  final bool showGhost;
  final bool showModel;
  final String? targetGlobalId;
  final Set<String> selected;

  /// GlobalId → progress colour, when colouring by progress.
  final Map<String, Color> statusColors;
  final Set<String> snagGlobalIds;

  /// GlobalIds the legend or the Layers switches filter out: not drawn, so
  /// the discipline chips can be tried in Demo mode too.
  final Set<String> hidden;
  final double opacity;

  /// The nudge, drawn as a small shift of the model so it visibly moves.
  final double nudgePx;
}

/// Demo mode's camera stand-in: the plant room from the design canvas,
/// drawn in flat perspective, with the sample MEP model laid over it once
/// placed. Elements are tappable ([demoHit]) so selection, progress and
/// snags can be tried without native AR. Everything here is illustration —
/// the Demo banner is always on screen above it.
class ArDemoScene extends StatefulWidget {
  const ArDemoScene({super.key, required this.scene});

  final ArDemoSceneState scene;

  /// Which sample element (by GlobalId) is at a screen fraction, if any.
  static String? demoHit(Offset fraction) {
    for (final r in _regions.reversed) {
      if (r.hit(fraction)) return r.globalId;
    }
    return null;
  }

  /// Sample elements whose region centre lies inside a lasso (fractions).
  static List<String> demoLasso(List<Offset> polygon) {
    final out = <String>[];
    for (final r in _regions) {
      if (_inside(polygon, r.centre)) out.add(r.globalId);
    }
    return out;
  }

  /// Where a floating label hangs on a sample element (view fractions):
  /// long runs near their start, where the lines are apart; boxes at the top
  /// centre. Demo mode's stand-in for the engine's `projectTile`.
  static Offset? demoAnchor(String globalId) {
    for (final r in _regions) {
      if (r.globalId != globalId) continue;
      if (r.rect.width > 0.3) return Offset(r.rect.left + 0.14, r.rect.center.dy);
      if (r.kind == 'ahu') return r.rect.topCenter;
      return r.rect.center;
    }
    return null;
  }

  @override
  State<ArDemoScene> createState() => _ArDemoSceneState();
}

bool _inside(List<Offset> poly, Offset p) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i];
    final b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) && p.dx < (b.dx - a.dx) * (p.dy - a.dy) / ((b.dy - a.dy) == 0 ? 1e-9 : (b.dy - a.dy)) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

class _Region {
  const _Region(this.globalId, this.rect, this.kind, {this.circle = false});
  final String globalId;

  /// Fractions of the view.
  final Rect rect;

  /// pipe | return | duct | tray | valve | ahu | riser
  final String kind;
  final bool circle;

  bool hit(Offset f) => rect.inflate(0.02).contains(f);
  Offset get centre => rect.center;
}

const _regions = <_Region>[
  _Region('demo-gid-duct', Rect.fromLTRB(0.20, 0.115, 1.0, 0.165), 'duct'),
  _Region('demo-gid-chw-s1', Rect.fromLTRB(0.20, 0.200, 1.0, 0.228), 'pipe'),
  _Region('demo-gid-chw-r1', Rect.fromLTRB(0.20, 0.246, 1.0, 0.272), 'return'),
  _Region('demo-gid-tray', Rect.fromLTRB(0.20, 0.300, 1.0, 0.314), 'tray'),
  _Region('demo-gid-chw-s2', Rect.fromLTRB(0.855, 0.214, 0.883, 0.56), 'riser'),
  _Region('demo-gid-chw-s3', Rect.fromLTRB(0.40, 0.370, 0.87, 0.394), 'pipe'),
  _Region('demo-gid-iv12', Rect.fromLTRB(0.70, 0.193, 0.745, 0.236), 'valve', circle: true),
  _Region('demo-gid-iv13', Rect.fromLTRB(0.50, 0.240, 0.54, 0.278), 'valve', circle: true),
  _Region('demo-gid-ahu03', Rect.fromLTRB(0.58, 0.56, 0.93, 0.76), 'ahu'),
];

class _ArDemoSceneState extends State<ArDemoScene> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))
    ..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => CustomPaint(
          size: Size.infinite,
          painter: _ScenePainter(scene: widget.scene, pulse: _pulse.value),
        ),
      ),
    );
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter({required this.scene, required this.pulse});
  final ArDemoSceneState scene;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    Offset p(double x, double y) => Offset(x * w, y * h);
    Path poly(List<Offset> pts) => Path()..addPolygon(pts, true);

    // The room: ceiling, left wall, back wall, floor (canvas M-boards).
    canvas.drawRect(Offset.zero & size, Paint()..color = FeArColors.cameraFloor);
    canvas.drawPath(poly([p(0, 0), p(1, 0), p(1, 0.13), p(0.18, 0.14), p(0, 0.05)]), Paint()..color = FeArColors.cameraCeiling);
    canvas.drawPath(poly([p(0, 0.05), p(0.18, 0.14), p(0.18, 0.70), p(0, 0.83)]), Paint()..color = FeArColors.cameraWallSide);
    canvas.drawPath(poly([p(0.18, 0.14), p(1, 0.13), p(1, 0.71), p(0.18, 0.70)]), Paint()..color = FeArColors.cameraWall);
    // Door on the left wall.
    canvas.drawPath(
      poly([p(0.03, 0.30), p(0.13, 0.31), p(0.13, 0.71), p(0.03, 0.76)]),
      Paint()..color = FeArColors.cameraDoor,
    );
    canvas.drawPath(
      poly([p(0.03, 0.30), p(0.13, 0.31), p(0.13, 0.71), p(0.03, 0.76)]),
      Paint()
        ..color = FeArColors.cameraDoorFrame
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    // A trim line (the real cable tray the model should sit on).
    canvas.drawRect(Rect.fromLTRB(0.18 * w, 0.20 * h, w, 0.22 * h), Paint()..color = FeArColors.cameraTrim.withValues(alpha: 0.25));
    // A column in front of the back wall (corner snapping target).
    canvas.drawPath(poly([p(0.40, 0.12), p(0.48, 0.15), p(0.48, 0.78), p(0.40, 0.74)]), Paint()..color = FeArColors.cameraTrim);
    canvas.drawPath(poly([p(0.48, 0.15), p(0.55, 0.12), p(0.55, 0.74), p(0.48, 0.78)]), Paint()..color = FeArColors.cameraWallSide);
    // A bin at the column's foot (the "hidden base" in S2).
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(0.40 * w, 0.70 * h, 0.52 * w, 0.80 * h), const Radius.circular(8)),
      Paint()..color = FeArColors.cameraEquipment,
    );

    if (scene.showBoard) _board(canvas, size);
    if (scene.showGrid) _grid(canvas, size);
    if (scene.placed) _edges(canvas, size);
    if (scene.placed && scene.showModel) _model(canvas, size);
    if (scene.showGhost) _ghost(canvas, size);
  }

  void _board(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = Rect.fromLTRB(0.64 * w, 0.34 * h, 0.80 * w, 0.50 * h);
    canvas.drawRect(r, Paint()..color = FeArColors.boardPaper);
    final q = r.deflate(r.width * 0.16);
    final qr = Rect.fromCenter(center: q.center, width: math.min(q.width, q.height), height: math.min(q.width, q.height));
    canvas.drawRect(
      qr,
      Paint()
        ..color = FeArColors.boardInk
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    final cell = qr.width / 7;
    final rnd = math.Random(scene.boardLabel.hashCode);
    for (var i = 1; i < 6; i++) {
      for (var j = 1; j < 6; j++) {
        if (rnd.nextBool()) {
          canvas.drawRect(Rect.fromLTWH(qr.left + i * cell, qr.top + j * cell, cell, cell), Paint()..color = FeArColors.boardInk);
        }
      }
    }
  }

  void _grid(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()
      ..color = FeArColors.gridline
      ..strokeWidth = 4;
    void dash(Offset a, Offset b) {
      final total = (b - a).distance;
      final dir = (b - a) / total;
      const pattern = [26.0, 9.0, 5.0, 9.0];
      var t = 0.0;
      var i = 0;
      while (t < total) {
        final len = pattern[i % 4];
        if (i.isEven) canvas.drawLine(a + dir * t, a + dir * math.min(total, t + len), paint);
        t += len;
        i++;
      }
    }

    dash(Offset(0.47 * w, 0.78 * h), Offset(0.62 * w, h));
    dash(Offset(0, 0.86 * h), Offset(w, 0.80 * h));
  }

  void _edges(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final dx = scene.nudgePx;
    final paint = Paint()
      ..color = FeArColors.edge.withValues(alpha: scene.locked ? 0.95 : 0.7)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(0.18 * w + dx, 0.14 * h)
      ..lineTo(w + dx, 0.13 * h)
      ..moveTo(0.18 * w + dx, 0.14 * h)
      ..lineTo(0.18 * w + dx, 0.70 * h)
      ..lineTo(w + dx, 0.71 * h)
      ..moveTo(0.03 * w + dx, 0.30 * h)
      ..lineTo(0.13 * w + dx, 0.31 * h)
      ..lineTo(0.13 * w + dx, 0.71 * h)
      ..moveTo(0.48 * w + dx, 0.15 * h)
      ..lineTo(0.48 * w + dx, 0.78 * h);
    canvas.drawPath(path, paint);
  }

  Color _baseColor(String kind) => switch (kind) {
    'duct' => FeColors.success,
    'return' => FeColors.primary,
    'tray' => FeColors.warning,
    'ahu' => FeArColors.snap,
    'valve' => FeColors.danger,
    _ => FeColors.info,
  };

  void _model(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final a = scene.opacity.clamp(0.15, 1.0).toDouble();
    for (final r in _regions) {
      if (scene.hidden.contains(r.globalId)) continue;
      final rect = Rect.fromLTRB(r.rect.left * w + scene.nudgePx, r.rect.top * h, r.rect.right * w + scene.nudgePx, r.rect.bottom * h);
      final selected = scene.selected.contains(r.globalId);
      final target = scene.targetGlobalId == r.globalId;
      final status = scene.statusColors[r.globalId];
      final base = status ?? _baseColor(r.kind);
      final fill = Paint()..color = (selected ? FeArColors.snap : base).withValues(alpha: (selected ? 0.95 : 0.72) * a);
      if (r.kind == 'ahu') {
        // Behind the wall: drawn x-ray (dashed outline, faint fill).
        canvas.drawRect(rect, Paint()..color = base.withValues(alpha: 0.18 * a));
        _dashedRect(
          canvas,
          rect,
          Paint()
            ..color = (selected || target ? FeArColors.snap : base).withValues(alpha: a)
            ..strokeWidth = 2.5
            ..style = PaintingStyle.stroke,
        );
      } else if (r.circle) {
        canvas.drawCircle(rect.center, rect.shortestSide / 2, fill);
        canvas.drawCircle(
          rect.center,
          rect.shortestSide / 2,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.9 * a)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      } else {
        canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(rect.shortestSide / 2)), fill);
      }
      if (selected) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect.inflate(3), const Radius.circular(6)),
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      if (target) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect.inflate(6 + 10 * pulse), const Radius.circular(10)),
          Paint()
            ..color = FeColors.danger.withValues(alpha: 0.8 * (1 - pulse))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3,
        );
      }
      if (scene.snagGlobalIds.contains(r.globalId)) {
        final pin = Offset(rect.center.dx, rect.top - 18);
        canvas.drawCircle(pin, 9, Paint()..color = FeArColors.snagPin);
        canvas.drawCircle(
          pin,
          9,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  void _dashedRect(Canvas canvas, Rect r, Paint paint) {
    void dash(Offset a, Offset b) {
      final total = (b - a).distance;
      final dir = (b - a) / total;
      var t = 0.0;
      while (t < total) {
        canvas.drawLine(a + dir * t, a + dir * math.min(total, t + 10), paint);
        t += 16;
      }
    }

    dash(r.topLeft, r.topRight);
    dash(r.topRight, r.bottomRight);
    dash(r.bottomRight, r.bottomLeft);
    dash(r.bottomLeft, r.topLeft);
  }

  void _ghost(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = Rect.fromLTRB(0.24 * w, 0.33 * h, 0.36 * w, 0.49 * h).inflate(3 * pulse);
    canvas.drawRect(r, Paint()..color = Colors.white.withValues(alpha: 0.18));
    _dashedRect(
      canvas,
      r,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
    _dashedRect(
      canvas,
      r.deflate(r.width * 0.2),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _ScenePainter old) => old.pulse != pulse || old.scene != scene;
}

/// Where the Demo scene draws the ghost outline (fractions), for its label.
const kArDemoGhostAnchor = Offset(0.30, 0.50);

/// Helper for screens: the sample feature for a GlobalId.
ArFeature? arDemoFeature(List<ArFeature> features, String? globalId) {
  if (globalId == null) return null;
  for (final f in features) {
    if (f.globalId == globalId) return f;
  }
  return null;
}
