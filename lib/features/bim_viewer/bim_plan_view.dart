import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ar/vec.dart';
import '../../core/bim_viewer/bim_view_wire.dart';
import '../../core/bim_viewer/plan_view_math.dart';
import '../../state/ar_view_models.dart';
import '../../state/bim_viewer_controller.dart';
import '../../theme/fe_colors.dart';
import '../../theme/app_font.dart';

/// The 2D half of the model viewer (docs/bim-viewer.md §5): the floor's
/// plan cut from the model (rooms, walls, columns, doors, equipment, grid),
/// drawn as vectors so it stays sharp at any zoom, with the 3D camera's
/// position dot and view cone on top.
///
/// Not the raster floor-plan image of `FloorPlanScreen` (FR-2.8): that one
/// is an uploaded picture with pins; this one is the model itself, in the
/// same frame as the 3D tiles, so a tap here is a place in 3D with no
/// calibration step.
///
/// Gestures: one finger pans, two pinch-zoom about the fingers, double-tap
/// zooms in, a tap selects equipment or moves the 3D camera there. The
/// viewport is its own maths ([PlanViewport]) rather than an
/// InteractiveViewer, so strokes keep a constant pixel width while zooming
/// and the overlay needs no second transform.
class BimPlanView extends StatefulWidget {
  const BimPlanView({
    super.key,
    required this.plan,
    required this.bounds,
    this.gridLines = const [],
    this.pose,
    this.selection,
    this.onTap,
    this.follow = false,
  });

  final ArPlan? plan;
  final List<double> bounds;
  final List<ArGridLine> gridLines;
  final BimPose? pose;
  final BimSelection? selection;

  /// A tap at a plan point, with the tolerance a fingertip covers there.
  final void Function(Vec2 planPoint, double toleranceM)? onTap;

  /// Keep the position dot in view (walk mode in split view).
  final bool follow;

  @override
  State<BimPlanView> createState() => _BimPlanViewState();
}

class _BimPlanViewState extends State<BimPlanView> {
  PlanViewport? _vp;
  Size _size = Size.zero;
  PlanViewport? _gestureStart;
  Offset _focalStart = Offset.zero;
  Offset? _lastTapDown;

  static Vec2 _v(Offset o) => Vec2(o.dx, o.dy);

  void _fit(Size size) {
    _vp = PlanViewport.fit(widget.bounds, size.width, size.height);
  }

  @override
  void didUpdateWidget(BimPlanView old) {
    super.didUpdateWidget(old);
    if (old.bounds.join(',') != widget.bounds.join(',') && _size != Size.zero) _fit(_size);
    final pose = widget.pose;
    final vp = _vp;
    if (widget.follow && pose != null && vp != null && !vp.shows(pose.planPoint, _size.width, _size.height, marginPx: 48)) {
      _vp = vp.centreOn(pose.planPoint, _size.width, _size.height);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      if (_vp == null || _size != size) {
        final first = _vp == null;
        _size = size;
        if (first) _fit(size);
      }
      final vp = _vp!;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (d) {
          _gestureStart = vp;
          _focalStart = d.localFocalPoint;
        },
        onScaleUpdate: (d) {
          final start = _gestureStart;
          if (start == null) return;
          final panned = start.panBy(_v(d.localFocalPoint - _focalStart));
          setState(() => _vp = d.scale == 1.0 ? panned : panned.zoomAbout(_v(d.localFocalPoint), d.scale));
        },
        onScaleEnd: (_) => _gestureStart = null,
        onTapDown: (d) => _lastTapDown = d.localPosition,
        onTap: () {
          final at = _lastTapDown;
          if (at == null) return;
          final p = vp.toPlan(_v(at));
          widget.onTap?.call(p, 22 / vp.scale);
        },
        onDoubleTapDown: (d) => _lastTapDown = d.localPosition,
        onDoubleTap: () {
          final at = _lastTapDown;
          if (at == null) return;
          setState(() => _vp = vp.zoomAbout(_v(at), 2));
        },
        child: ClipRect(
          child: CustomPaint(
            size: size,
            painter: _PlanPainter(
              plan: widget.plan,
              gridLines: widget.gridLines,
              vp: vp,
              pose: widget.pose,
              selection: widget.selection,
              aspect: size.height == 0 ? 1 : size.width / size.height,
            ),
          ),
        ),
      );
    });
  }
}

class _PlanPainter extends CustomPainter {
  _PlanPainter({
    required this.plan,
    required this.gridLines,
    required this.vp,
    required this.pose,
    required this.selection,
    required this.aspect,
  });

  final ArPlan? plan;
  final List<ArGridLine> gridLines;
  final PlanViewport vp;
  final BimPose? pose;
  final BimSelection? selection;
  final double aspect;

  Offset _o(Vec2 p) {
    final s = vp.toScreen(p);
    return Offset(s.x, s.y);
  }

  Path _poly(List<Vec2> pts, {bool close = true}) {
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final o = _o(pts[i]);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    if (close) path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = FeColors.page);
    _paintGrid(canvas, size);
    final p = plan;
    if (p != null) _paintPlan(canvas, p);
    _paintSelection(canvas);
    _paintPose(canvas);
  }

  void _paintGrid(Canvas canvas, Size size) {
    if (gridLines.isEmpty) return;
    final line = Paint()
      ..color = FeColors.ink2.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final bubbleFill = Paint()..color = FeColors.panel;
    final bubbleEdge = Paint()
      ..color = FeColors.ink2.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final g in gridLines) {
      final a = _o(g.p0), b = _o(g.p1);
      _dashed(canvas, a, b, line);
      for (final end in [a, b]) {
        canvas.drawCircle(end, 9, bubbleFill);
        canvas.drawCircle(end, 9, bubbleEdge);
        _label(canvas, g.name, end, 9, FeColors.ink2, bold: true);
      }
    }
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final d = b - a;
    final len = d.distance;
    if (len < 1) return;
    final dir = d / len;
    const dash = 10.0, gap = 5.0;
    for (var t = 0.0; t < len; t += dash + gap) {
      canvas.drawLine(a + dir * t, a + dir * math.min(len, t + dash), paint);
    }
  }

  void _paintPlan(Canvas canvas, ArPlan p) {
    // Rooms first, then equipment, walls and columns on top.
    final roomFill = Paint()..color = FeColors.infoSoft;
    final roomEdge = Paint()
      ..color = FeColors.info.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final s in p.spaces) {
      if (s.polygon.length < 3) continue;
      final path = _poly(s.polygon);
      canvas.drawPath(path, roomFill);
      canvas.drawPath(path, roomEdge);
    }

    final eqFill = Paint()..color = FeColors.primary.withValues(alpha: 0.14);
    final eqLinked = Paint()..color = FeColors.primary.withValues(alpha: 0.26);
    final eqEdge = Paint()
      ..color = FeColors.primary.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final e in p.equipment) {
      if (e.polygon.length < 3) continue;
      final path = _poly(e.polygon);
      canvas.drawPath(path, e.assetId != null ? eqLinked : eqFill);
      canvas.drawPath(path, eqEdge);
    }

    // Walls: at least 2 px; ~0.2 m thick when zoomed in.
    final wall = Paint()
      ..color = FeColors.ink
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter
      ..strokeWidth = math.max(2.0, 0.2 * vp.scale);
    for (final w in p.walls) {
      if (w.length < 2) continue;
      canvas.drawPath(_poly(w, close: false), wall);
    }
    final col = Paint()..color = FeColors.ink;
    for (final c in p.columns) {
      if (c.length < 3) continue;
      canvas.drawPath(_poly(c), col);
    }
    // Door openings: a gap in the page colour, and a swing hint.
    final gap = Paint()
      ..color = FeColors.page
      ..strokeWidth = math.max(2.0, 0.2 * vp.scale) + 1
      ..strokeCap = StrokeCap.butt;
    final swing = Paint()
      ..color = FeColors.ink2
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final d in p.doors) {
      if (d.length < 2) continue;
      final a = _o(d[0]), b = _o(d[1]);
      canvas.drawLine(a, b, gap);
      final r = (b - a).distance;
      if (r > 6) {
        final start = math.atan2(b.dy - a.dy, b.dx - a.dx);
        canvas.drawArc(Rect.fromCircle(center: a, radius: r), start, -math.pi / 2, false, swing);
      }
    }

    // Room names where there's room for them.
    if (vp.scale > 6) {
      for (final s in p.spaces) {
        if (s.name.trim().isEmpty) continue;
        final w = _widthPx(s.polygon);
        if (w < 48) continue;
        _label(canvas, s.name, _o(s.labelAt), math.min(w * 0.9, 160), FeColors.ink2);
      }
    }
  }

  double _widthPx(List<Vec2> poly) {
    if (poly.isEmpty) return 0;
    final xs = poly.map((v) => v.x);
    return (xs.reduce(math.max) - xs.reduce(math.min)) * vp.scale;
  }

  void _paintSelection(Canvas canvas) {
    final sel = selection;
    if (sel == null) return;
    final fill = Paint()..color = FeColors.warning.withValues(alpha: 0.35);
    final edge = Paint()
      ..color = FeColors.warning
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    final poly = sel.planPolygon;
    if (poly != null && poly.length >= 3) {
      final path = _poly(poly);
      canvas.drawPath(path, fill);
      canvas.drawPath(path, edge);
      return;
    }
    final min = sel.bboxMin, max = sel.bboxMax;
    if (min != null && max != null) {
      final r = Rect.fromPoints(_o(min.xz), _o(max.xz));
      final grown = r.width < 12 || r.height < 12 ? Rect.fromCenter(center: r.center, width: math.max(12, r.width), height: math.max(12, r.height)) : r;
      canvas.drawRect(grown, fill);
      canvas.drawRect(grown, edge);
    }
  }

  void _paintPose(Canvas canvas) {
    final ps = pose;
    if (ps == null) return;
    final at = ps.planPoint;
    final heading = ps.planHeading;
    if (heading != null) {
      final cone = viewCone(at, heading, horizontalFovDeg(ps.fovDeg, aspect), ps.mode == BimCameraMode.walk ? 6 : 4);
      final path = _poly(cone);
      final shader = RadialGradient(
        colors: [FeColors.primary.withValues(alpha: 0.38), FeColors.primary.withValues(alpha: 0.02)],
      ).createShader(Rect.fromCircle(center: _o(at), radius: (ps.mode == BimCameraMode.walk ? 6 : 4) * vp.scale));
      canvas.drawPath(path, Paint()..shader = shader);
    }
    final c = _o(at);
    canvas.drawCircle(c, 9, Paint()..color = Colors.white);
    canvas.drawCircle(c, 6.5, Paint()..color = FeColors.primary);
  }

  void _label(Canvas canvas, String text, Offset centre, double maxWidth, Color color, {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontFamily: kAppFont, fontSize: bold ? 10 : 11, color: color, fontWeight: bold ? FontWeight.w700 : FontWeight.w600),
      ),
      textAlign: TextAlign.center,
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(8, maxWidth));
    tp.paint(canvas, centre - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_PlanPainter old) =>
      old.plan != plan ||
      old.vp != vp ||
      old.pose != pose ||
      old.selection != selection ||
      old.gridLines != gridLines ||
      old.aspect != aspect;
}
